package com.clarklevis.dsh.android

import com.clarklevis.dsh.shared.protocol.GatewayWireDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobilePluginTest {
    @Test
    fun catalogKeepsDisabledRowsAndUsesBundleState() {
        val frame = GatewayWireDecoder.decode("""
            {
              "kind":"plugin-catalog", "requestId":"catalog-1", "managementAvailable":true,
              "settingsWritable":true,
              "bundles":[
                {"name":"@deepseek-ai/dsh-base","enabled":true,"installed":true,"optional":false,"removable":false,"rows":[]},
                {"name":"official","enabled":false,"installed":false,"optional":true,"removable":false,"rows":[]},
                {"name":"third-party","enabled":false,"installed":true,"optional":false,"removable":true,
                 "meta":{"title":{"zh":"测试插件","en":"Test Plugin"},"icon":"data:image/svg+xml;base64,PHN2Zy8+"},
                 "rows":[{"rowId":"inactive","moduleName":"inactive-module"},
                         {"rowId":"active","moduleName":"active-module","entryId":"entry-1"}]},
                {"name":"broken","enabled":false,"installed":false,"optional":false,"removable":false,
                 "error":{"code":"invalid-spec"},"rows":[]}
              ],
              "plugins":[{"entryId":"entry-1","enabled":true,"fiberPhase":"active"}],
              "officialItems":[{"id":"shell","namespaces":["bash-sandbox"]}]
            }
        """.trimIndent())
        val catalog = MobilePluginCatalog(
            frame.managementAvailable == true, frame.settingsWritable == true,
            frame.bundles.orEmpty().map(::MobilePluginBundle),
            frame.plugins.orEmpty().map(::MobilePluginEntry),
            frame.officialItems.orEmpty().map(::MobileOfficialPlugin)
        )
        assertEquals(listOf("official"), catalog.officialBundles.map { it.name })
        assertEquals(listOf("broken", "third-party"), catalog.installedBundles.map { it.name })
        val bundle = catalog.installedBundles.last()
        assertFalse(bundle.enabled)
        assertEquals("data:image/svg+xml;base64,PHN2Zy8+", bundle.icon)
        val inactive = MobilePluginRow(bundle.rows[0], null)
        assertEquals("inactive", inactive.rowId)
        assertFalse(inactive.enabled)
        assertEquals(null, inactive.entryId)
        val active = MobilePluginRow(bundle.rows[1], catalog.plugins.first())
        assertTrue(active.enabled)
        assertEquals("entry-1", active.entryId)
        assertEquals("invalid-spec", catalog.installedBundles.first().error)
    }

    @Test
    fun bundleOrderDoesNotChangeWithEnablementOrHostResponseOrder() {
        val before = listOf(
            bundle("dsh-host-zeta", enabled = true),
            bundle("@deepseek-ai/dsh-client-alpha", enabled = false),
            bundle("dsh-beta", enabled = true)
        )
        val after = listOf(
            bundle("dsh-beta", enabled = false),
            bundle("dsh-host-zeta", enabled = false),
            bundle("@deepseek-ai/dsh-client-alpha", enabled = true)
        )
        val expected = listOf("@deepseek-ai/dsh-client-alpha", "dsh-beta", "dsh-host-zeta")
        assertEquals(expected, MobilePluginCatalog(true, true, before, emptyList(), emptyList())
            .installedBundles.map { it.name })
        assertEquals(expected, MobilePluginCatalog(true, true, after, emptyList(), emptyList())
            .installedBundles.map { it.name })
    }

    @Test
    fun experimentalBadgeUsesGatewayFlagOnly() {
        val frame = GatewayWireDecoder.decode("""
            {"kind":"plugin-catalog","bundles":[
              {"name":"flagged","experimental":true},
              {"name":"@deepseek-ai/dsh-experimental-unflagged","experimental":false},
              {"name":"legacy"}
            ]}
        """.trimIndent())
        val bundles = frame.bundles.orEmpty().map(::MobilePluginBundle)
        assertTrue(bundles[0].experimental)
        assertFalse(bundles[1].experimental)
        assertFalse(bundles[2].experimental)
    }

    @Test
    fun pluginMetadataUsesChineseWhenAvailableAndFallsBackToEnglish() {
        val frame = GatewayWireDecoder.decode("""
            {"kind":"plugin-catalog","bundles":[
              {"name":"official","meta":{"title":{"zh":"自动化任务","en":"Automation tasks"},
                "description":{"zh":"按设定的时间执行任务。","en":"Run tasks on a schedule."}}},
              {"name":"english-only","meta":{"title":{"en":"English only"}}}
            ]}
        """.trimIndent())
        val bundles = frame.bundles.orEmpty().map(::MobilePluginBundle)
        assertEquals("自动化任务", bundles[0].title)
        assertEquals("按设定的时间执行任务。", bundles[0].description)
        assertEquals("English only", bundles[1].title)
    }

    private fun bundle(name: String, enabled: Boolean): MobilePluginBundle {
        val frame = GatewayWireDecoder.decode("""
            {"kind":"plugin-catalog","bundles":[{"name":"$name","enabled":$enabled,
              "installed":true,"optional":false,"removable":true,"rows":[]}]}
        """.trimIndent())
        return MobilePluginBundle(frame.bundles!!.single())
    }
}
