package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.projection.ConversationItemKind
import com.clarklevis.dsh.shared.projection.ConversationProjector
import com.clarklevis.dsh.shared.protocol.GatewayEvent
import com.clarklevis.dsh.shared.protocol.GatewayWireDecoder
import com.clarklevis.dsh.shared.protocol.SessionEvent
import kotlin.test.*

class ErrorDetailsProjectionTest {
    private fun live(seq: Int, event: String): SessionEvent {
        val frame = GatewayWireDecoder.decode("""{"kind":"event","sessionId":"s","seq":$seq,"time":$seq,"event":$event}""")
        return SessionEvent("s", seq, seq.toDouble(), requireNotNull(frame.event))
    }

    private val failure = """{"message":"Rate limited","code":"RATE_LIMIT","status":429}"""
    private fun attempt() = live(1, """{"type":"assistant/attempt","turn":1,"step":0,"finish":{"kind":"error","failure":$failure}}""")
    private fun retry() = live(2, """{"type":"llm/retry","turn":1,"step":0,"retryId":"r","retry":1,"maxRetries":5,"delayMs":1000,"failure":$failure}""")

    @Test
    fun retryReplacesFailedAttemptAndKeepsFailureWhenRequestStarts() {
        val projector = ConversationProjector()
        projector.fold(listOf(attempt(), retry()))
        assertEquals(1, projector.items.size)
        assertTrue(projector.items.single().title.startsWith("Retrying model request (1/5)"))
        assertTrue(projector.items.single().text.contains("Rate limited (RATE_LIMIT · HTTP 429)"))
        assertFalse(projector.items.single().isError)
        val id = projector.items.single().id
        projector.fold(listOf(live(3, """{"type":"llm/retry-started","turn":1,"step":0,"retryId":"r","retry":1}""")))
        assertEquals(id, projector.items.single().id)
        assertTrue(projector.items.single().title.startsWith("Model request retried (1/5)"))
        assertTrue(projector.items.single().text.contains("HTTP 429"))
        projector.fold(listOf(live(4, """{"type":"assistant/message","turn":1,"step":0,"text":"Done"}"""),
            live(5, """{"type":"turn/end","turn":1,"reason":"completed"}""")))
        assertEquals("Done", projector.items.last().text)
        assertTrue(projector.items.none { it.title.contains("interrupted") })
    }

    @Test
    fun finalErrorHasProviderDetailsInsteadOfGenericInterruptedMessage() {
        val events = listOf(attempt(), live(2, """{"type":"turn/end","turn":1,"reason":"error","reasonDetails":{"kind":"error","error":$failure}}"""))
        val projector = ConversationProjector().apply { rebuild(events) }
        assertEquals(1, projector.items.size)
        assertEquals("Generation failed", projector.items.single().title)
        assertTrue(projector.items.single().isError)
        assertTrue(projector.items.single().text.contains("RATE_LIMIT"))
    }

    @Test
    fun cancellationDuringRetryProducesOneNonErrorNotice() {
        val projector = ConversationProjector().apply { fold(listOf(attempt(), retry(),
            live(3, """{"type":"turn/end","turn":1,"reason":"aborted","reasonDetails":{"kind":"aborted","reason":{"kind":"user"}}}"""))) }
        assertEquals(1, projector.items.size)
        assertEquals("Generation cancelled", projector.items.single().title)
        assertFalse(projector.items.single().isError)
    }

    @Test
    fun interruptedProcessRemainsDistinctFromCancellation() {
        val projector = ConversationProjector().apply { fold(listOf(live(1, """{"type":"turn/end","turn":1,"reason":"interrupted"}"""))) }
        assertEquals("Generation interrupted", projector.items.single().title)
        assertTrue(projector.items.single().isError)
    }

    @Test
    fun historicalDiagnosticsSurviveRebuildWithoutTokenStream() {
        val frame = GatewayWireDecoder.decode("""{"kind":"history","events":[{"type":"assistant/attempt","seq":1,"time":1,"data":{"turn":1,"step":0,"finish":{"kind":"error","failure":$failure}}},{"type":"llm/retry","seq":2,"time":2,"data":{"turn":1,"step":0,"retryId":"r","retry":1,"maxRetries":5,"delayMs":1000,"failure":$failure}},{"type":"llm/retry-started","seq":3,"time":3,"data":{"turn":1,"step":0,"retryId":"r","retry":1}}]}""")
        val records = frame.events.orEmpty().map { it.normalized("s") }
        val projector = ConversationProjector().apply { rebuild(records) }
        assertEquals(1, projector.items.size)
        assertTrue(projector.items.single().title.startsWith("Model request retried (1/5)"))
        assertTrue(projector.items.single().text.contains("HTTP 429"))
    }

    @Test
    fun toolOutputRetainsStderrAndProcessExitWithoutFailingTheTurn() {
        val events = listOf(live(1, """{"type":"tool/result","isError":false,"preview":"short","output":"[stderr]\nOperation not permitted\n[sandbox: file access denied]\n[exit code: 1]","outputTruncated":true}"""),
            live(2, """{"type":"assistant/message","turn":1,"step":1,"text":"Continue after approval"}"""))
        val projector = ConversationProjector().apply { rebuild(events) }
        val tool = projector.items.first()
        assertEquals(ConversationItemKind.TOOL_RESULT, tool.kind)
        assertEquals("Tool failed", tool.title)
        assertTrue(tool.text.contains("Operation not permitted"))
        assertTrue(tool.text.contains("[exit code: 1]"))
        assertTrue(tool.text.contains("Output truncated"))
        assertTrue(tool.isError)
        assertEquals("Continue after approval", projector.items.last().text)
        assertFalse(projector.items.last().isError)
    }

    @Test
    fun structuredToolFailureWithoutTextHasUsefulFallback() {
        val event = live(1, """{"type":"tool/result","isError":true,"error":{"message":"Permission denied","code":"DENIED"}}""")
        val projector = ConversationProjector().apply { fold(listOf(event)) }
        assertEquals("Permission denied", projector.items.single().text)
        assertEquals("Tool failed", projector.items.single().title)
    }

    @Test
    fun rawHistoricalToolResultUsesOutputAndStructuredError() {
        val frame = GatewayWireDecoder.decode("""{"kind":"history","events":[{"type":"tool/result","seq":1,"time":1,"data":{"message":{"toolCallId":"c","isError":true,"content":[{"type":"text","text":"short"}]},"output":"full stderr","outputTruncated":false,"error":{"message":"Denied","code":"DENIED"}}}]}""")
        val event = frame.events.orEmpty().single().normalized("s")
        val tool = ConversationProjector().apply { fold(listOf(event)) }.items.single()
        assertTrue(tool.text.contains("full stderr"))
        assertTrue(tool.text.contains("Denied (DENIED)"))
    }
}
