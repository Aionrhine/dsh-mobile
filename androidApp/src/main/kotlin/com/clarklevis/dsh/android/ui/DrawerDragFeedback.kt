package com.clarklevis.dsh.android.ui

import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.Interaction
import androidx.compose.foundation.interaction.MutableInteractionSource

/** 在 Stop 发出时同步反馈，早于收尾动画；Cancel 和旧拖拽的 Stop 不反馈。 */
internal class DrawerDragFeedback(
    private val source: MutableInteractionSource = MutableInteractionSource(),
    private val onRelease: () -> Unit
) : MutableInteractionSource by source {
    private var activeDrag: DragInteraction.Start? = null

    override suspend fun emit(interaction: Interaction) {
        handle(interaction)
        source.emit(interaction)
    }

    override fun tryEmit(interaction: Interaction): Boolean {
        val emitted = source.tryEmit(interaction)
        if (emitted) handle(interaction)
        return emitted
    }

    private fun handle(interaction: Interaction) {
        when (interaction) {
            is DragInteraction.Start -> activeDrag = interaction
            is DragInteraction.Stop -> if (activeDrag === interaction.start) {
                activeDrag = null
                onRelease()
            }
            is DragInteraction.Cancel -> if (activeDrag === interaction.start) activeDrag = null
        }
    }
}
