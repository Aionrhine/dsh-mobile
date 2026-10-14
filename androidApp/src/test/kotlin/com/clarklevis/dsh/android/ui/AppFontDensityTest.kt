package com.clarklevis.dsh.android.ui

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Test

class AppFontDensityTest {
    @Test fun scaleOnlyChangesTextAndPreservesInverseConversion() {
        val density = AppFontDensity(Density(2f, 1.3f), 1.5f)
        with(density) {
            assertEquals(20f, 10.dp.toPx(), 0.001f)
            assertEquals(39f, 10.sp.toPx(), 0.001f)
            assertEquals(10f, 10.sp.toDp().toSp().value, 0.001f)
        }
    }

    @Test fun customSystemFontConversionIsPreserved() {
        val system = object : Density {
            override val density = 2f
            override val fontScale = 2f
            override fun TextUnit.toDp(): Dp = (value * 1.4f).dp
            override fun Dp.toSp(): TextUnit = (value / 1.4f).sp
        }
        with(AppFontDensity(system, 1.5f)) {
            assertEquals(42f, 10.sp.toPx(), 0.001f)
            assertEquals(10f, 10.sp.toDp().toSp().value, 0.001f)
        }
    }

    @Test fun invalidStoredScalesUseSafeDefaultsAndLimits() {
        assertEquals(1f, normalizeFontScale(Float.NaN), 0f)
        assertEquals(1f, normalizeFontScale(Float.POSITIVE_INFINITY), 0f)
        assertEquals(0.8f, normalizeFontScale(0f), 0f)
        assertEquals(1.5f, normalizeFontScale(4f), 0f)
    }
}
