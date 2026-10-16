package com.clarklevis.dsh.android.ui

import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionStatsPopoverGeometryTest {
    @Test
    fun `popover above capsule points down and scales from capsule center`() {
        val anchor = IntRect(580, 800, 740, 834)
        val size = IntSize(332, 260)
        val placement = placement(anchor, IntSize(800, 1_000), size)

        assertFalse(placement.pointsUp)
        assertEquals(anchor.top - 6, placement.position.y + size.height - 16)
        assertEquals(anchor.right, placement.position.x + size.width - 16)
        assertEquals(660f, placement.position.x + 16 + placement.arrowX, 0.001f)
        assertCapsuleIsScaleOrigin(placement, anchor, size)
    }

    @Test
    fun `capsule near top opens below with an upward arrow`() {
        val anchor = IntRect(580, 20, 740, 54)
        val size = IntSize(332, 260)
        val placement = placement(anchor, IntSize(800, 1_000), size)

        assertTrue(placement.pointsUp)
        assertEquals(anchor.bottom + 6, placement.position.y + 16)
        assertCapsuleIsScaleOrigin(placement, anchor, size)
    }

    @Test
    fun `narrow window clamps popup while retaining the capsule scale origin`() {
        val anchor = IntRect(10, 400, 130, 434)
        val size = IntSize(320, 260)
        val placement = placement(anchor, IntSize(320, 640), size)

        assertEquals(0, placement.position.x)
        assertEquals(54f, placement.arrowX, 0.001f)
        assertCapsuleIsScaleOrigin(placement, anchor, size)
    }

    @Test
    fun `right to left aligns the card leading edge with the capsule`() {
        val anchor = IntRect(50, 700, 210, 734)
        val placement = placement(anchor, IntSize(800, 1_000), IntSize(332, 260), LayoutDirection.Rtl)

        assertEquals(anchor.left, placement.position.x + 16)
    }

    @Test
    fun `constrained height selects more space and permits scrolling without covering capsule`() {
        val anchor = IntRect(500, 290, 650, 324)
        val window = IntSize(800, 640)
        val initial = placement(anchor, window, IntSize(332, 560))
        assertTrue(initial.pointsUp)
        assertEquals(294, initial.surfaceHeightLimit)

        val resized = placement(anchor, window, IntSize(332, initial.surfaceHeightLimit + 32))
        assertTrue(resized.pointsUp)
        assertEquals(anchor.bottom + 6, resized.position.y + 16)
        assertTrue(resized.position.y + initial.surfaceHeightLimit + 32 <= window.height)
    }

    private fun placement(
        anchor: IntRect,
        window: IntSize,
        popup: IntSize,
        direction: LayoutDirection = LayoutDirection.Ltr
    ) = calculateSessionStatsPopoverPlacement(anchor, window, popup, direction, shadowPadding = 16, gap = 6)

    private fun assertCapsuleIsScaleOrigin(
        placement: SessionStatsPopoverPlacement,
        anchor: IntRect,
        size: IntSize
    ) {
        assertEquals(
            (anchor.left + anchor.right) / 2f,
            placement.position.x + placement.transformOrigin.pivotFractionX * size.width,
            0.001f
        )
        assertEquals(
            (anchor.top + anchor.bottom) / 2f,
            placement.position.y + placement.transformOrigin.pivotFractionY * size.height,
            0.001f
        )
    }
}
