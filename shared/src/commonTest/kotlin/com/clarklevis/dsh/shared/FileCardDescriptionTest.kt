package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.FileCardDescription
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FileCardDescriptionTest {
    @Test
    fun keepsSummaryAndPageCountWithoutExpandedDetails() {
        assertEquals(
            "2026 国庆海南三亚旅游攻略 · A4 共 8 页",
            FileCardDescription.summary("2026 国庆海南三亚旅游攻略 · A4 共 8 页（天气/交通/住宿/7 日行程/门票预约/美食/免税避坑）")
        )
        assertEquals("报告 · 8 页", FileCardDescription.summary("报告 · 8 页 (天气,交通,住宿)。"))
        assertEquals("报告 · 8 页", FileCardDescription.summary("报告 · 8 页（交通（市内/机场）、住宿）。"))
    }

    @Test
    fun preservesNormalDescriptionsAndRevisionNotes() {
        assertEquals("A4 · 8 页 · 交付文件", FileCardDescription.summary("A4 · 8 页 · 交付文件"))
        assertEquals("报告（修订版）", FileCardDescription.summary("报告（修订版）"))
        assertEquals("报告（修订版） · 8 页", FileCardDescription.summary("报告（修订版） · 8 页（天气/交通）"))
        assertEquals("报告（天气/交通", FileCardDescription.summary("报告（天气/交通"))
        assertEquals("旅行攻略 · 8 页", FileCardDescription.summary(" 旅行攻略\n ·  8 页 "))
    }

    @Test
    fun omitsEmptyDescriptionsAndStandaloneDetailLists() {
        assertNull(FileCardDescription.summary(null))
        assertNull(FileCardDescription.summary(" \n "))
        assertNull(FileCardDescription.summary("（天气/交通/住宿）"))
    }
}
