package com.clarklevis.dsh.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AppReleaseInfoTest {
    @Test fun usesReportedDshVersionRatherThanGatewayPlaceholder() {
        assertEquals("0.2.0-rc.2", dshHostVersion("0.2.0-rc.2", "remote-gateway"))
        assertEquals("未提供", dshHostVersion(null, "remote-gateway"))
        assertEquals("0.1.7-rc.1", dshHostVersion(null, "0.1.7-rc.1"))
    }
}
