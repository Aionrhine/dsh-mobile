package com.clarklevis.dsh.android.ui

import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View

/** 普通点击作为中等触感，预先创建效果，松手时直接播放并尊重系统触感设置。 */
internal class DrawerHapticFeedback(private val view: View) {
    private val vibrator = view.context.getSystemService(Vibrator::class.java)?.takeIf { it.hasVibrator() }
    private val click = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
    } else {
        null
    }
    private val audioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    @Suppress("DEPRECATION")
    fun perform() {
        if (!view.isHapticFeedbackEnabled) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU &&
            Settings.System.getInt(view.context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) == 0
        ) {
            return
        }
        val motor = vibrator
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && motor != null && click != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                motor.vibrate(click, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
            } else {
                motor.vibrate(click, audioAttributes)
            }
        } else {
            view.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
        }
    }
}
