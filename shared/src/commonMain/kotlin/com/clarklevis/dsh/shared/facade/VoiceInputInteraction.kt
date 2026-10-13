package com.clarklevis.dsh.shared.facade

/** 两端共用的按住说话交互参数；平台只执行手势计时和蒙层动画。 */
object VoiceInputInteraction {
    // 留出短按识别窗口；蒙层快速显现，录音硬件在后台启动。
    const val LONG_PRESS_MILLISECONDS = 80L
    const val OVERLAY_HEIGHT_FRACTION = 0.4
    const val OVERLAY_FADE_IN_MILLISECONDS = 160
    const val OVERLAY_FADE_OUT_MILLISECONDS = 280
    const val CAPTURE_TAIL_MILLISECONDS = 200L
}
