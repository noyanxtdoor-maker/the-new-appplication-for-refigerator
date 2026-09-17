package com.nexttransfer.rmplanner

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

/**
 * Writes a portable Next Transfer backup straight into the user-visible
 * Downloads folder.
 *
 * This is deliberately narrow. Android's MediaStore `Downloads` collection
 * (API 29+) exists precisely so an app can add a user-visible document without
 * any runtime permission, and that is the only path implemented here. On API
 * 24–28 the same write would require `WRITE_EXTERNAL_STORAGE`; this app
 * deliberately does not request a broad storage permission, so below API 29 the
 * channel reports "not supported" and Dart falls back to the Storage Access
 * Framework picker, which needs no permission either.
 *
 * The write is verified before it is published and before anything is reported
 * to the user: the item stays pending while the stored bytes are read back and
 * hashed, and that digest must equal the digest of what was written. A backup
 * is only "created" when the bytes that can be read back are the bytes that
 * were written.
 *
 * The stored length is checked too, but only when the platform reports one.
 * `MediaStore.Downloads.SIZE` is genuinely `null` for an item that is still
 * pending — measured on Android 15 on the owner's device — so requiring it
 * rejected correctly stored backups. The digest is the strong check: it cannot
 * match unless every byte reached the file, which implies the length.
 */
object BackupDownloadsWriter {
    const val CHANNEL = "com.nexttransfer.rmplanner/backup_downloads"

    private const val METHOD_WRITE_BACKUP = "writeBackup"

    /** Diagnostic tag. Message text never contains file contents. */
    private const val TAG = "NTBackupWriter"

    /**
     * Registers the channel. Called once from the activity's engine setup, with
     * the activity context so no static context is ever retained.
     */
    fun register(channel: MethodChannel, context: Context) {
        channel.setMethodCallHandler { call, result ->
            if (call.method != METHOD_WRITE_BACKUP) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val fileName = call.argument<String>("fileName")
            val bytes = call.argument<ByteArray>("bytes")
            val expectedSha256 = call.argument<String>("sha256")
            if (fileName.isNullOrBlank() || bytes == null || expectedSha256.isNullOrBlank()) {
                result.success(null)
                return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                // No permission-free route to public Downloads on this OS.
                result.success(null)
                return@setMethodCallHandler
            }
            try {
                result.success(write(context, fileName, bytes, expectedSha256))
            } catch (error: Exception) {
                result.error("backup_downloads_failed", error.message, null)
            }
        }
    }

    /**
     * Inserts [bytes] into MediaStore's Downloads collection, verifies the
     * stored result, then publishes it.
     *
     * Returns the real stored location, byte count and digest, or null when the
     * insert itself was refused.
     *
     * [expectedSha256] is the digest of the bytes the app handed over. The
     * returned `sha256` is the digest the platform computed from the bytes it
     * can read back, so the caller can prove for itself that the stored bytes
     * are the written bytes.
     */
    private fun write(
        context: Context,
        fileName: String,
        bytes: ByteArray,
        expectedSha256: String,
    ): Map<String, Any?>? {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY,
        )
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val item = resolver.insert(collection, values) ?: return null
        try {
            resolver.openOutputStream(item)?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: throw IllegalStateException("no output stream")

            // Verification happens while the item is still pending, so a bad
            // write is never visible to the user and never reported as success.
            val pendingSize = readSize(resolver, item)
            val storedSha = readSha256(resolver, item)
            if (storedSha == null || storedSha != expectedSha256) {
                // The bytes that can be read back are not the bytes that were
                // written. Nothing is published and nothing is reported.
                android.util.Log.w(TAG, "nt_backup_write_failed reason=digest")
                throw IllegalStateException("stored backup did not verify")
            }
            if (pendingSize != null && pendingSize != bytes.size.toLong()) {
                android.util.Log.w(TAG, "nt_backup_write_failed reason=length")
                throw IllegalStateException("stored backup length did not verify")
            }

            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(item, values, null, null)

            // Publishing makes the item visible, and on this device it also
            // makes the platform report the length it stored. Both are checked
            // where the platform offers them; a reported length that disagrees
            // with what was written is a real failure.
            val publishedSize = readSize(resolver, item)
            if (publishedSize != null && publishedSize != bytes.size.toLong()) {
                android.util.Log.w(TAG, "nt_backup_write_failed reason=published_length")
                throw IllegalStateException("published backup length did not verify")
            }

            // The platform is free to rename on a display-name collision, so the
            // reported location is the name it actually settled on.
            val display =
                readString(resolver, item, MediaStore.Downloads.DISPLAY_NAME)
                    ?: fileName
            return mapOf(
                "location" to "Downloads/$display",
                "byteLength" to (publishedSize ?: pendingSize ?: bytes.size.toLong()),
                "sha256" to storedSha,
            )
        } catch (error: Exception) {
            // Only the item this call created is ever removed.
            resolver.delete(item, null, null)
            throw error
        }
    }

    private fun readSize(resolver: android.content.ContentResolver, item: Uri): Long? {
        resolver.query(item, arrayOf(MediaStore.Downloads.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst() && !cursor.isNull(0)) {
                    return cursor.getLong(0)
                }
            }
        return null
    }

    private fun readString(
        resolver: android.content.ContentResolver,
        item: Uri,
        column: String,
    ): String? {
        resolver.query(item, arrayOf(column), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getString(0)
            }
        }
        return null
    }

    private fun readSha256(
        resolver: android.content.ContentResolver,
        item: Uri,
    ): String? {
        val digest = MessageDigest.getInstance("SHA-256")
        resolver.openInputStream(item)?.use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = stream.read(buffer)
                if (read <= 0) {
                    break
                }
                digest.update(buffer, 0, read)
            }
        } ?: return null
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte)
        }
    }
}
