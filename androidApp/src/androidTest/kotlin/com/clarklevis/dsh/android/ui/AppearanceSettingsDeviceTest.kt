package com.clarklevis.dsh.android.ui

import android.content.Context
import android.content.res.Configuration
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertTrue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import java.util.Locale

class AppearanceSettingsDeviceTest {
    @get:Rule val compose = createComposeRule()

    @Test fun fontSizeEntryOpensSeparatePageAndReturnsWithSavedSelection() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("font-navigation-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val appearance = AppearanceSettings(preferences)
        try {
            compose.setContent {
                DshTheme(appearance) {
                    val navigation = rememberNavController()
                    NavHost(navigation, startDestination = "settings") {
                        composable("settings") {
                            FontSizeSettingsRow { navigation.navigate("font-size") }
                        }
                        composable("font-size") {
                            FontSizeSettingsScreen { navigation.popBackStack() }
                        }
                    }
                }
            }
            compose.onNodeWithTag("font-size-preview-title").assertDoesNotExist()
            compose.onNodeWithText("字体大小").performClick()
            compose.onNodeWithTag("font-size-preview-title").assertIsDisplayed()
            compose.onNodeWithContentDescription("字体大小")
                .performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
            compose.onNodeWithContentDescription("返回").performClick()
            compose.onNodeWithTag("font-size-preview-title").assertDoesNotExist()
            compose.onNodeWithText("150%").assertIsDisplayed()
            compose.runOnIdle { assertEquals(1.5f, AppearanceSettings(preferences).fontScale, 0.001f) }
        } finally {
            preferences.edit().clear().commit()
        }
    }

    @Test fun fontSliderResizesAllTextPathsImmediatelyAndPersists() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("font-scale-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val appearance = AppearanceSettings(preferences)
        try {
            compose.setContent {
                DshTheme(appearance) {
                    Column {
                        Text("默认文字", modifier = Modifier.testTag("default-font"))
                        Text("固定字号", fontSize = 14.sp, modifier = Modifier.testTag("explicit-font"))
                        DshMarkdownText("**Markdown** 和 `代码`", modifier = Modifier.testTag("markdown-font"))
                        FontSizeControls()
                    }
                }
            }
            val tags = listOf("default-font", "explicit-font", "markdown-font")
            val heights = tags.associateWith { compose.onNodeWithTag(it).fetchSemanticsNode().boundsInRoot.height }
            compose.onNodeWithContentDescription("字体大小")
                .performSemanticsAction(SemanticsActions.SetProgress) { it(1.5f) }
            compose.onNodeWithText("150%").assertIsDisplayed()
            tags.forEach { tag ->
                val height = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height
                assertTrue("$tag 应跟随字体设置放大", height > heights.getValue(tag) * 1.2f)
            }
            compose.runOnIdle { assertEquals(1.5f, AppearanceSettings(preferences).fontScale, 0.001f) }
            compose.onNodeWithContentDescription("跟随系统字体大小").performClick()
            compose.runOnIdle {
                val saved = AppearanceSettings(preferences)
                assertTrue(saved.fontFollowsSystem)
                assertEquals(1f, saved.effectiveFontScale, 0.001f)
                assertEquals(1.5f, saved.fontScale, 0.001f)
            }
            tags.forEach { tag ->
                val height = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.height
                assertEquals(heights.getValue(tag), height, 1f)
            }
            compose.onNodeWithContentDescription("跟随系统字体大小").performClick()
            compose.onNodeWithText("150%").assertIsDisplayed()
            compose.onNodeWithText("恢复默认").performClick()
            compose.onNodeWithText("标准").assertIsDisplayed()
            compose.runOnIdle { assertEquals(1f, AppearanceSettings(preferences).fontScale, 0.001f) }
        } finally {
            preferences.edit().clear().commit()
        }
    }

    @Test fun languageRowSavesSelectionAndRestoresSystemLocaleOnNextLaunch() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("language-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val appearance = AppearanceSettings(preferences)
        val originalLocale = Locale.getDefault()
        try {
            compose.setContent { DshTheme(appearance) { LanguageSettingsRow() } }
            compose.onNodeWithText("语言").performClick()
            compose.onNodeWithText("简体中文").performClick()
            compose.onNodeWithText("简体中文").assertIsDisplayed()
            compose.runOnIdle {
                val saved = AppearanceSettings(preferences)
                assertEquals(AppLanguage.SIMPLIFIED_CHINESE, saved.language)
                val englishContext = context.createConfigurationContext(Configuration(context.resources.configuration).apply {
                    setLocale(Locale.US)
                })
                val chineseContext = AppearanceSettings.localizedContext(englishContext, saved.language)
                assertEquals("zh", chineseContext.resources.configuration.locales[0].language)
                assertEquals("zh", Locale.getDefault().language)
            }
            compose.onNodeWithText("语言").performClick()
            compose.onNodeWithText("跟随系统").performClick()
            compose.runOnIdle {
                val saved = AppearanceSettings(preferences)
                assertEquals(AppLanguage.SYSTEM, saved.language)
                val englishContext = context.createConfigurationContext(Configuration(context.resources.configuration).apply {
                    setLocale(Locale.US)
                })
                val systemContext = AppearanceSettings.localizedContext(englishContext, saved.language)
                assertEquals("en", systemContext.resources.configuration.locales[0].language)
                assertEquals("en", Locale.getDefault().language)
            }
        } finally {
            Locale.setDefault(originalLocale)
            preferences.edit().clear().commit()
        }
    }

    @Test fun themeRowSwitchesImmediatelyPersistsAndReturnsToSystem() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = context.getSharedPreferences("appearance-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val appearance = AppearanceSettings(preferences)
        var systemDark by mutableStateOf(false)
        try {
            compose.setContent {
                val configuration = Configuration(LocalConfiguration.current).apply {
                    uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                        if (systemDark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                }
                CompositionLocalProvider(LocalConfiguration provides configuration) {
                    DshTheme(appearance) {
                        Column {
                            InterfaceStyleSettingsRow()
                            Text(if (isSystemInDarkTheme()) "effective-dark" else "effective-light")
                        }
                    }
                }
            }
            compose.onNodeWithText("effective-light").assertIsDisplayed()
            compose.onNodeWithText("界面").performClick()
            compose.onNodeWithText("深色").performClick()
            compose.onNodeWithText("effective-dark").assertIsDisplayed()
            compose.runOnIdle {
                assertEquals(InterfaceStyle.DARK, AppearanceSettings(preferences).interfaceStyle)
            }
            compose.onNodeWithText("界面").performClick()
            compose.onNodeWithText("浅色").performClick()
            compose.runOnIdle { systemDark = true }
            compose.onNodeWithText("effective-light").assertIsDisplayed()
            compose.onNodeWithText("界面").performClick()
            compose.onNodeWithText("跟随系统").performClick()
            compose.onNodeWithText("effective-dark").assertIsDisplayed()
            compose.runOnIdle { systemDark = false }
            compose.onNodeWithText("effective-light").assertIsDisplayed()
        } finally {
            preferences.edit().clear().commit()
        }
    }
}
