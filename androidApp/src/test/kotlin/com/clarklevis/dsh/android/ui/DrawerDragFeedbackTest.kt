package com.clarklevis.dsh.android.ui

import androidx.compose.foundation.interaction.DragInteraction
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class DrawerDragFeedbackTest {
    @Test
    fun releaseFiresSynchronouslyOnceForEachDrag() = runBlocking {
        var pulses = 0
        val feedback = DrawerDragFeedback { pulses++ }
        repeat(2) {
            val start = DragInteraction.Start()
            feedback.emit(start)
            assertEquals(it, pulses)
            feedback.emit(DragInteraction.Stop(start))
            assertEquals(it + 1, pulses)
            feedback.emit(DragInteraction.Stop(start))
            assertEquals(it + 1, pulses)
        }
    }

    @Test
    fun cancellationDoesNotPulseAndNextReleaseStillWorks() = runBlocking {
        var pulses = 0
        val feedback = DrawerDragFeedback { pulses++ }
        val cancelled = DragInteraction.Start()
        feedback.emit(cancelled)
        feedback.tryEmit(DragInteraction.Cancel(cancelled))
        feedback.emit(DragInteraction.Stop(cancelled))
        assertEquals(0, pulses)
        val next = DragInteraction.Start()
        feedback.emit(next)
        feedback.emit(DragInteraction.Stop(next))
        assertEquals(1, pulses)
    }

    @Test
    fun staleReleaseDoesNotEndTheNewDrag() = runBlocking {
        var pulses = 0
        val feedback = DrawerDragFeedback { pulses++ }
        val old = DragInteraction.Start()
        feedback.emit(old)
        feedback.emit(DragInteraction.Cancel(old))
        val next = DragInteraction.Start()
        feedback.emit(next)
        feedback.emit(DragInteraction.Stop(old))
        assertEquals(0, pulses)
        feedback.emit(DragInteraction.Stop(next))
        assertEquals(1, pulses)
    }
}
