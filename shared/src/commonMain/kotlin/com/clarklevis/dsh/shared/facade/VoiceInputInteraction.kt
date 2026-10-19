package com.clarklevis.dsh.shared.facade

/** 两端共用的按住说话交互参数；平台只执行手势计时和蒙层动画。 */
object VoiceInputInteraction {
    // 专用语音区域使用相同的短按识别窗口；文字输入区域不安装录音手势。
    const val LONG_PRESS_MILLISECONDS = 80L
    const val OVERLAY_HEIGHT_FRACTION = 0.4
    const val OVERLAY_FADE_IN_MILLISECONDS = 160

    // 入场上移距离：Android 使用 dp，iOS 使用 pt。
    const val OVERLAY_ENTER_OFFSET = 18
    const val OVERLAY_FADE_OUT_MILLISECONDS = 280
    const val CAPTURE_TAIL_MILLISECONDS = 200L
    const val CAPTURE_WINDOW_MILLISECONDS = 20L
}
