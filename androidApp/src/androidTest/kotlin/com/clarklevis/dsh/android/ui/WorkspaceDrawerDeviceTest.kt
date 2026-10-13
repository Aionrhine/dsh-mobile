package com.clarklevis.dsh.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class WorkspaceDrawerDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun settlingDoesNotRecomposeHomeOnEveryAnimationFrame() {
        var contentCompositions = 0
        compose.setContent {
            MaterialTheme {
                WorkspaceDrawer(onPlugins = {}, onScheduledTasks = {}) { openDrawer, canScroll ->
                    SideEffect { contentCompositions++ }
                    Box(Modifier.fillMaxSize()) {
                        Button(onClick = openDrawer, modifier = Modifier.testTag("open-drawer")) {
                            Text("打开")
                        }
                        Text(if (canScroll) "可滚动" else "暂停滚动")
                    }
                }
            }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        val initialCompositions = contentCompositions
        compose.onNodeWithTag("open-drawer").performClick()
        repeat(12) {
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
        }
        compose.runOnIdle {
            val animationCompositions = contentCompositions - initialCompositions
            assertTrue(
                "首页只能在交互状态变化时重组，12 个动画帧实际重组 $animationCompositions 次",
                animationCompositions <= 3
            )
        }
        compose.mainClock.autoAdvance = true
    }

    @Test
    fun swipingOpensDrawerAndClosingRestoresVerticalScroll() {
        compose.setContent {
            MaterialTheme {
                WorkspaceDrawer(onPlugins = {}, onScheduledTasks = {}) { _, canScroll ->
                    Text(
                        if (canScroll) "可滚动" else "暂停滚动",
                        modifier = Modifier.testTag(if (canScroll) "scroll-enabled" else "scroll-disabled")
                    )
                }
            }
        }
        compose.onNodeWithTag("workspace-drawer-main").performTouchInput { swipeRight() }
        compose.onNodeWithTag("drawer-scheduled-tasks").assertIsDisplayed()
        compose.onNodeWithTag("scroll-disabled").assertIsDisplayed()
        compose.onNodeWithTag("workspace-drawer-main").performTouchInput { swipeLeft() }
        compose.onNodeWithTag("scroll-enabled").assertIsDisplayed()
    }

    @Test
    fun tappingExposedHomeClosesDrawerWithoutInvokingHomeAction() {
        var homeClicks = 0
        var pluginClicks = 0
        compose.setContent {
            MaterialTheme {
                WorkspaceDrawer(onPlugins = { pluginClicks++ }, onScheduledTasks = {}) { openDrawer, _ ->
                    Column {
                        Button(onClick = openDrawer, modifier = Modifier.testTag("open-drawer")) {
                            Text("打开")
                        }
                        Button(onClick = { homeClicks++ }, modifier = Modifier.testTag("home-action")) {
                            Text("首页操作")
                        }
                    }
                }
            }
        }
        compose.onNodeWithTag("open-drawer").performClick()
        compose.onNodeWithTag("workspace-drawer-close").performTouchInput {
            down(center)
            up()
        }
        compose.onNodeWithTag("open-drawer").performClick()
        compose.onNodeWithTag("drawer-plugins").performClick()
        compose.runOnIdle {
            assertEquals(0, homeClicks)
            assertEquals(1, pluginClicks)
        }
    }
}
