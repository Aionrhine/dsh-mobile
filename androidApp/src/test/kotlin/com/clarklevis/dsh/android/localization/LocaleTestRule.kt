package com.clarklevis.dsh.android.localization

import java.util.Locale
import org.junit.rules.ExternalResource

class LocaleTestRule(private val locale: Locale = Locale.SIMPLIFIED_CHINESE) : ExternalResource() {
    private lateinit var previous: Locale

    override fun before() {
        previous = Locale.getDefault()
        Locale.setDefault(locale)
    }

    override fun after() {
        Locale.setDefault(previous)
    }
}
