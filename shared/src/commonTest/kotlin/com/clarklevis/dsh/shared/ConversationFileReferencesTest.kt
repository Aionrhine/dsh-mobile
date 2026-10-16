package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.ConversationFileReferences
import com.clarklevis.dsh.shared.facade.SharedWorkspaceFileStore
import com.clarklevis.dsh.shared.projection.ConversationProjector
import com.clarklevis.dsh.shared.protocol.*
import kotlinx.serialization.decodeFromString
import kotlin.test.*

class ConversationFileReferencesTest {
    @Test
    fun historyAndLiveDeliverablesDecodeIdentically() {
        val history = wireJson.decodeFromString<RawSessionEvent>(
            """{"type":"deliverables/presented","seq":4,"time":1,"data":{"turn":2,"callId":"p1","files":[{"path":"build/旅游.pdf","description":"8 页"}]}}"""
        ).normalized("s1")
        val live = GatewayWireDecoder.decode(
            """{"kind":"event","sessionId":"s1","seq":4,"time":1,"event":{"type":"deliverables/presented","turn":2,"callId":"p1","files":[{"path":"build/旅游.pdf","description":"8 页"}]}}"""
        ).event!!
        assertEquals(live.files, history.event.files)
        assertEquals(live.callId, history.event.callId)
        assertEquals(live.turn, history.event.turn)
    }

    @Test
    fun filesWaitForTheirTurnAndMoveToLastReplyWithoutDuplication() {
        val projector = ConversationProjector()
        val first = SessionEvent("s1", 1, 1.0, GatewayEvent("deliverables/presented", turn = 2,
            files = listOf(PresentedFile("a/report.pdf", "初版"))))
        projector.fold(listOf(first, first))
        assertTrue(projector.items.isEmpty())
        projector.fold(listOf(reply(2, 1), reply(3, 2)))
        assertTrue(projector.items.first().files.isEmpty())
        assertEquals("初版", projector.items.last().files.single().description)
        projector.fold(listOf(reply(4, 2), SessionEvent("s1", 5, 1.0,
            GatewayEvent("deliverables/presented", turn = 2, files = listOf(
                PresentedFile("a/report.pdf", "新版"), PresentedFile("b/report.pdf"))))))
        assertTrue(projector.items[1].files.isEmpty())
        assertEquals(listOf("a/report.pdf", "b/report.pdf"), projector.items.last().files.map { it.path })
        assertEquals("新版", projector.items.last().files.first().description)
        assertEquals(projector.items.last().files, projector.items[1].knownFiles)
        projector.rebuild(listOf(first, reply(3, 2)))
        assertEquals(1, projector.items.single().files.size)
    }

    @Test
    fun linksPreserveSpecialNamesAndDecodeOnlyOnce() {
        assertEquals("build/旅游 攻略.pdf", ConversationFileReferences.filePath("<build/%E6%97%85%E6%B8%B8%20攻略.pdf#L24-L30>"))
        assertEquals("/work/a%20b.pdf", ConversationFileReferences.filePath("file:///work/a%2520b.pdf"))
        assertEquals("a#chapter.pdf", ConversationFileReferences.filePath("a#chapter.pdf"))
        assertEquals("a+b.pdf", ConversationFileReferences.filePath("a+b.pdf"))
        assertEquals("C:\\work\\a.pdf", ConversationFileReferences.filePath("C:\\work\\a.pdf"))
        assertEquals("C:\\work\\a.pdf", ConversationFileReferences.filePath("C:%5Cwork%5Ca.pdf"))
        assertEquals("\\\\host\\share\\a.pdf", ConversationFileReferences.filePath("\\\\host\\share\\a.pdf"))
        listOf("https://example.com/a.pdf", "dsh-resource://a", "mailto:a@b.com", "#section", "file://remote/a", "%zz").forEach {
            assertNull(ConversationFileReferences.filePath(it), it)
        }
    }

    @Test
    fun inlineCodeRequiresExactOrUniqueKnownFile() {
        val paths = listOf("a/report.pdf", "b/report.pdf", "build/旅游.pdf")
        assertNull(ConversationFileReferences.knownPath("report.pdf", paths))
        assertNull(ConversationFileReferences.knownPath("unknown.pdf", paths))
        assertEquals("a/report.pdf", ConversationFileReferences.knownPath("a/report.pdf", paths))
        assertEquals("build/旅游.pdf", ConversationFileReferences.knownPath("旅游.pdf", paths))
    }

    @Test
    fun resolveCorrelatesAndUsesCanonicalDownloadPath() {
        val store = SharedWorkspaceFileStore()
        assertEquals("file-resolve", store.resolve("s1", "/work/旅游.pdf", "r1", true).request?.requestType)
        assertNull(store.acceptFrame(resolved("old", "s1")).request)
        assertNull(store.acceptFrame(resolved("r1", "other")).request)
        val opened = store.acceptFrame(resolved("r1", "s1"))
        assertEquals("file-download-open", opened.request?.requestType)
        assertTrue(opened.request!!.payload.contains("build/旅游.pdf"))
        assertNull(opened.snapshot.lastError)
    }

    @Test
    fun cancelIgnoresLateResolveAndClosesLateOpenedTransfer() {
        val store = SharedWorkspaceFileStore()
        store.resolve("s1", "a.pdf", "r1", true)
        store.cancel()
        assertNull(store.acceptFrame(resolved("r1", "s1")).request)
        val late = store.acceptFrame("""{"kind":"file-download-opened","requestId":"r1-download","transferId":"old"}""")
        assertEquals("file-download-cancel", late.request?.requestType)
        assertNull(late.snapshot.lastError)
    }

    @Test
    fun legacyGatewayOnlyAcceptsSafeRelativePaths() {
        val store = SharedWorkspaceFileStore()
        assertEquals("file-references-upgrade-required", store.resolve("s1", "/work/a.pdf", "r1", false).snapshot.lastError)
        assertEquals("file-references-upgrade-required", store.resolve("s1", "../a.pdf", "r2", false).snapshot.lastError)
        assertEquals("file-references-upgrade-required", store.resolve("s1", "C:/work/a.pdf", "r3", false).snapshot.lastError)
        assertEquals("file-download-open", store.resolve("s1", "build/a.pdf", "r4", false).request?.requestType)
    }

    @Test
    fun errorsRespectRequestIdentityAndAllowRetry() {
        val store = SharedWorkspaceFileStore()
        store.resolve("s1", "a.pdf", "r1", true)
        assertNull(store.requestFailed("file-resolve", "missing", "old").snapshot.lastError)
        assertEquals("missing", store.requestFailed("file-resolve", "missing", "r1").snapshot.lastError)
        assertEquals("file-resolve", store.resolve("s1", "a.pdf", "r2", true).request?.requestType)
    }

    private fun reply(seq: Int, turn: Int) = SessionEvent("s1", seq, 1.0,
        GatewayEvent("assistant/message", turn = turn, step = seq, text = "回复"))

    private fun resolved(request: String, session: String) =
        """{"kind":"file-resolved","requestId":"$request","sessionId":"$session","path":"build/旅游.pdf","name":"旅游.pdf","mediaType":"application/pdf","size":123,"modifiedAt":1}"""
}
