package com.clarklevis.dsh.android.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.test.espresso.Espresso.pressBack
import com.clarklevis.dsh.shared.protocol.GatewayContextPressure
import com.clarklevis.dsh.shared.protocol.GatewaySessionStats
import com.clarklevis.dsh.shared.protocol.GatewaySessionStatsSnapshot
import com.clarklevis.dsh.shared.protocol.GatewaySessionTokenUsage
import com.clarklevis.dsh.shared.protocol.GatewaySessionTokenUsageTotals
import org.junit.Rule
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.util.Locale

class SessionStatusUiDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var previousLocale: Locale

    @Before
    fun useChineseTestCopy() {
        previousLocale = Locale.getDefault()
        Locale.setDefault(Locale.SIMPLIFIED_CHINESE)
    }

    @After
    fun restoreLocale() {
        Locale.setDefault(previousLocale)
    }

    @Test
    fun arrowIsPartOfTheCardOutlineForBothPlacementDirections() {
        for (pointsUp in listOf(false, true)) {
            val outline = SessionStatsPopoverShape(arrowX = 220f, pointsUp = pointsUp)
                .createOutline(Size(300f, 220f), LayoutDirection.Ltr, Density(1f)) as Outline.Generic
            val bitmap = Bitmap.createBitmap(300, 220, Bitmap.Config.ARGB_8888)
            try {
                Canvas(bitmap).drawPath(outline.path.asAndroidPath(), Paint().apply { color = Color.BLACK })
                val tipY = if (pointsUp) 1 else 218
                assertNotEquals("Arrow tip must be filled", Color.TRANSPARENT, bitmap.getPixel(220, tipY))
                assertEquals("Arrow must be narrower than the card", Color.TRANSPARENT, bitmap.getPixel(180, tipY))
                assertNotEquals("Card body must join the arrow", Color.TRANSPARENT, bitmap.getPixel(220, 110))
            } finally {
                bitmap.recycle()
            }
        }
    }

    @Test
    fun closingPopoverWaitsForShrinkAnimationAndAllowsReopening() {
        compose.setContent {
            DshTheme {
                SessionStatsBanner(
                    snapshot = GatewaySessionStatsSnapshot(stats = GatewaySessionStats(turns = 2, steps = 3)),
                    sessionId = "animation-test",
                    onViewFullStats = {}
                )
            }
        }
        compose.onNode(hasTestTag("session-stats-capsule")).performClick()
        compose.onNode(hasTestTag("session-stats-popover")).assertIsDisplayed()
        compose.mainClock.autoAdvance = false
        try {
            pressBack()
            compose.mainClock.advanceTimeByFrame()
            compose.mainClock.advanceTimeBy(64)
            compose.onNode(hasTestTag("session-stats-popover")).assertExists()
            compose.mainClock.advanceTimeBy(300)
            compose.onNode(hasTestTag("session-stats-popover")).assertDoesNotExist()
        } finally {
            compose.mainClock.autoAdvance = true
        }
        compose.onNode(hasTestTag("session-stats-capsule")).performClick()
        compose.onNode(hasTestTag("session-stats-popover")).assertIsDisplayed()
    }

    @Test
    fun capsuleOpensPopoverAndFullStatsSheet() {
        val snapshot = GatewaySessionStatsSnapshot(
            asOfSeq = 2_809,
            stats = GatewaySessionStats(
                turns = 2,
                steps = 3,
                llmMs = 27_100.0,
                toolMs = 36_200.0,
                ttftMs = 1_941.0,
                ttftSteps = 3,
                decodeMs = 900.0,
                decodeTokens = 100
            ),
            tokenUsage = GatewaySessionTokenUsage(
                GatewaySessionTokenUsageTotals(
                    inputTokens = 9_400,
                    outputTokens = 1_000,
                    cacheReadTokens = 2_000,
                    cacheWriteTokens = 100,
                    reasoningTokens = 500
                )
            ),
            contextPressure = GatewayContextPressure(
                pressureTokens = 9_400,
                projectedTokens = 10_400,
                contextWindow = 1_000_000
            )
        )
        compose.setContent {
            var showSheet by remember { mutableStateOf(false) }
            DshTheme {
                SessionStatsBanner(snapshot, "session-test") { showSheet = true }
                if (showSheet) SessionStatsSheet(snapshot) { showSheet = false }
            }
        }

        compose.onNode(hasTestTag("session-stats-capsule") and hasText("2 轮 · 3 步"))
            .assertIsDisplayed()
            .performClick()
        compose.onNode(hasTestTag("session-stats-popover")).assertIsDisplayed()
        compose.onNode(hasText("首 token 平均")).assertIsDisplayed()
        compose.onNode(hasTestTag("view-full-session-stats")).performClick()
        compose.onNode(hasTestTag("session-stats-sheet")).assertIsDisplayed()
        compose.onNode(hasText("会话状态")).assertIsDisplayed()
        compose.onNode(hasText("执行")).assertIsDisplayed()

        val sheetBottom = compose.onNode(hasTestTag("session-stats-sheet"))
            .fetchSemanticsNode().boundsInRoot.bottom
        val windowBottom = compose.onAllNodes(isRoot(), useUnmergedTree = true)
            .fetchSemanticsNodes().maxOf { it.boundsInRoot.bottom }
        assertTrue(
            "Bottom sheet must cover the window bottom: sheet=$sheetBottom, window=$windowBottom",
            sheetBottom >= windowBottom
        )
    }
}
