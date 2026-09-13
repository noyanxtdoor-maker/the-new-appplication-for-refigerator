package io.flutter.plugins.googlemaps;

import android.content.Context;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import com.google.android.gms.maps.GoogleMapOptions;
import com.google.android.gms.maps.MapView;

/** Maps-only tap interception. Pan, pinch and long press remain SDK gestures. */
final class NtPrecisionMapView extends MapView {
  NtMapInteraction interaction;
  private float downX, downY;
  private long downTime;
  private boolean tap;
  private boolean sdkControl;
  private final int slop;
  private final int controlBound;

  NtPrecisionMapView(Context context, GoogleMapOptions options) {
    super(context, options);
    slop = ViewConfiguration.get(context).getScaledTouchSlop();
    // The Maps SDK docks its built-in controls — the top-left needle compass
    // among them — as small views in the map's corners. NT's precision layer
    // owns map taps only. A press that starts on one of those controls must
    // keep the SDK's own click handling, because that click is the only path
    // that returns the camera to north-up when the compass is tapped. The map
    // surface and the marker overlay are never this small, so nothing else
    // matches this bound.
    controlBound = Math.round(48f * getResources().getDisplayMetrics().density);
  }

  @Override public boolean dispatchTouchEvent(MotionEvent event) {
    switch (event.getActionMasked()) {
      case MotionEvent.ACTION_DOWN:
        downX = event.getX(); downY = event.getY();
        downTime = event.getEventTime(); tap = true;
        sdkControl = overSdkControl(event.getX(), event.getY());
        break;
      case MotionEvent.ACTION_POINTER_DOWN:
      case MotionEvent.ACTION_CANCEL:
        tap = false; break;
      case MotionEvent.ACTION_MOVE:
        if (Math.hypot(event.getX() - downX, event.getY() - downY) > slop) tap = false;
        break;
      case MotionEvent.ACTION_UP:
        boolean completedTap = tap && event.getPointerCount() == 1
            && event.getEventTime() - downTime < ViewConfiguration.getLongPressTimeout()
            && Math.hypot(event.getX() - downX, event.getY() - downY) <= slop;
        boolean sdkOwnsTap = sdkControl;
        tap = false; sdkControl = false;
        if (completedTap && !sdkOwnsTap && interaction != null && interaction.enabled()) {
          // Cancel BEFORE the SDK sees UP: it cannot cycle to another marker,
          // open an info window, or execute default click camera centering.
          MotionEvent cancel = MotionEvent.obtain(event);
          cancel.setAction(MotionEvent.ACTION_CANCEL);
          super.dispatchTouchEvent(cancel);
          cancel.recycle();
          interaction.tap(event.getX(), event.getY());
          return true;
        }
        break;
      default: break;
    }
    return super.dispatchTouchEvent(event);
  }

  /**
   * True when the press starts inside a visible docked SDK control view, so the
   * SDK keeps that press and NT never consumes it.
   */
  private boolean overSdkControl(float x, float y) {
    return overControl(this, x, y, 0);
  }

  private boolean overControl(View parent, float x, float y, int depth) {
    if (depth > 6 || !(parent instanceof ViewGroup)) return false;
    ViewGroup group = (ViewGroup) parent;
    for (int index = 0; index < group.getChildCount(); index++) {
      View child = group.getChildAt(index);
      if (child.getVisibility() != View.VISIBLE || child.getAlpha() <= 0f) continue;
      float childX = x - child.getLeft() + group.getScrollX();
      float childY = y - child.getTop() + group.getScrollY();
      if (childX < 0 || childY < 0
          || childX >= child.getWidth() || childY >= child.getHeight()) continue;
      if (isSdkControl(child) || overControl(child, childX, childY, depth + 1)) return true;
    }
    return false;
  }

  /** Docked controls are a corner-sized view; the map surface never is. */
  private boolean isSdkControl(View view) {
    return view.getWidth() > 0 && view.getHeight() > 0
        && view.getWidth() <= controlBound && view.getHeight() <= controlBound;
  }
}
