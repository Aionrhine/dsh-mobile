package com.clarklevis.dsh.android.ui

import com.clarklevis.dsh.android.localization.LocaleTestRule
import org.junit.Rule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GatewaySwitcherStateTest {
    @get:Rule val locale = LocaleTestRule()

    @Test
    fun deleteActionTracksSelectionCount() {
        assertNull(gatewayDeleteActionLabel(0))
        assertEquals("删除", gatewayDeleteActionLabel(1))
        assertEquals("批量删除", gatewayDeleteActionLabel(2))
    }

    @Test
    fun radioSelectionCanAddAndRemoveMultipleHosts() {
        var selected = emptySet<String>()
        selected = toggleSelection(selected, "a")
        selected = toggleSelection(selected, "b")
        assertEquals(setOf("a", "b"), selected)
        assertEquals(setOf("b"), toggleSelection(selected, "a"))
    }
}
