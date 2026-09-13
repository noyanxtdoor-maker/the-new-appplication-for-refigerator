package com.nexttransfer.rmplanner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Broadcasts enqueue one bounded canonical recovery; they never start a service.
 *
 * M8 section 28: KEEP, not REPLACE.  A boot/time/timezone broadcast must not
 * cancel a recovery that is already running.  Losing a change that arrives
 * during a running pass is prevented by the durable reconciliation marker's
 * dirty generation plus the recovery pass's trailing pass, not by cancelling
 * and restarting the job.  The recovery task carries no input, so it always
 * re-reads all current truth when it executes.
 */
class ReminderRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(
                Intent.ACTION_BOOT_COMPLETED,
                Intent.ACTION_MY_PACKAGE_REPLACED,
                Intent.ACTION_TIME_CHANGED,
                Intent.ACTION_TIMEZONE_CHANGED,
            )) return
        val request = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(Data.Builder()
                .putString(BackgroundWorker.DART_TASK_KEY, "nt.reminder.recovery")
                .build())
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            "nt.reminder.recovery", ExistingWorkPolicy.KEEP, request)
    }
}
