package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.SharedVoiceInputStore
import com.clarklevis.dsh.shared.protocol.GatewayWireDecoder
import kotlin.io.encoding.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class SharedVoiceInputStoreTest {
    private fun ready(draft: String = ""): SharedVoiceInputStore {
        val store = SharedVoiceInputStore()
        store.open("session-1", draft)
        val opening = store.connectionChanged(true, true)
        val request = opening.requests.first { it.requestType == "speech-catalog" }
        store.acceptJson(
            """{"kind":"speech-catalog","requestId":"${request.correlationId}","available":true,"maxAudioBytes":4194304,"maxDurationSeconds":120,"selection":{"providerId":"sensevoice-local","language":"zh"},"providers":[{"id":"sensevoice-local","languages":["auto","zh","en"],"preparation":{"phase":"ready"}}]}""",
        )
        assertTrue(store.snapshot().ready)
        return store
    }

    private fun capture(store: SharedVoiceInputStore): String {
        val token =
            store
                .press(1000)
                .effects
                .first { it.action == "permission" }
                .recordingId
        assertEquals(
            "start",
            store
                .permissionResult(token, true, 1001)
                .effects
                .single()
                .action,
        )
        store.captureStarted(token, 1002)
        return token
    }

    private fun transcribe(store: SharedVoiceInputStore): String {
        val token = capture(store)
        store.release(1400)
        val request = store.captureFinished(token, Base64.encode(ByteArray(16000)), 1401).requests.single()
        assertEquals("speech-transcribe", request.requestType)
        assertEquals(185_000, request.timeoutMilliseconds)
        assertTrue(request.payload.contains("sensevoice-local"))
        assertTrue(request.payload.contains("\"language\":\"auto\""))
        return token
    }

    @Test fun keyboardControlsHintWithoutStartingMicrophone() {
        val store = ready()
        assertEquals("输入内容或按住说话", store.snapshot().hint)
        store.keyboardChanged(true)
        assertEquals("描述你想要构建的内容", store.snapshot().hint)
        assertTrue(store.press(1000).effects.isEmpty())
        store.keyboardChanged(false)
        assertTrue(store.snapshot().hint.endsWith("或按住说话"))
    }

    @Test fun releaseTranscribesAndFillsDraftWithoutSending() {
        val store = ready("原草稿")
        val token = transcribe(store)
        val result = store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"新内容"}""")
        assertEquals("原草稿\n新内容", result.draftUpdate)
        assertEquals("idle", result.snapshot.phase)
        assertTrue(result.requests.isEmpty())
    }

    @Test fun wavIsEncodedInCommonLayer() {
        val store = ready()
        val token = capture(store)
        store.release(1500)
        val request = store.captureFinished(token, Base64.encode(ByteArray(16000)), 1501).requests.single()
        val encoded = Regex("\"audioBase64\":\"([^\"]+)\"").find(request.payload)!!.groupValues[1]
        val wave = Base64.decode(encoded)
        assertEquals("RIFF", wave.copyOfRange(0, 4).decodeToString())
        assertEquals("WAVEfmt ", wave.copyOfRange(8, 16).decodeToString())
        assertEquals(38444, wave.size)
        assertEquals(0x80, wave[24].toInt() and 255)
        assertEquals(0x3e, wave[25].toInt() and 255)
    }

    @Test fun changedDraftNeedsExplicitInsertion() {
        val store = ready("原草稿")
        val token = transcribe(store)
        store.draftChanged("用户新输入")
        val result = store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"录音文字"}""")
        assertEquals(null, result.draftUpdate)
        assertEquals("录音文字", result.snapshot.pendingTranscript)
        assertEquals("用户新输入\n录音文字", store.insertPending().draftUpdate)
    }

    @Test fun swipeCancelDiscardsAudioAndLateCallbacks() {
        val store = ready()
        val token = capture(store)
        store.pointerMoved(-80f)
        val cancelled = store.release(1500)
        assertTrue(cancelled.effects.any { it.action == "stop" && it.discard })
        assertTrue(store.captureFinished(token, Base64.encode(ByteArray(16000)), 1501).requests.isEmpty())
        assertEquals("idle", store.snapshot().phase)
    }

    @Test fun permissionReleasedBeforeGrantCannotStartCapture() {
        val store = ready()
        val token =
            store
                .press(1000)
                .effects
                .first { it.action == "permission" }
                .recordingId
        store.release(1200)
        assertTrue(store.permissionResult(token, true, 1300).effects.isEmpty())
        assertEquals("idle", store.snapshot().phase)
    }

    @Test fun timeoutCancelsRemoteAndRejectsLateSuccess() {
        val store = ready()
        val token = transcribe(store)
        assertEquals(
            "speech-cancel",
            store
                .tick(181402)
                .requests
                .single()
                .requestType,
        )
        assertEquals(
            null,
            store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"迟到"}""").draftUpdate,
        )
    }

    @Test fun changingContextOrDisconnectingStopsOwnedRecording() {
        val store = ready()
        val token = transcribe(store)
        assertEquals(
            "speech-cancel",
            store
                .open("session-2", "")
                .requests
                .single()
                .requestType,
        )
        assertEquals(
            null,
            store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"旧会话"}""").draftUpdate,
        )
        val next = capture(store)
        val disconnected = store.connectionChanged(false, false)
        assertTrue(disconnected.effects.any { it.recordingId == next && it.discard })
        assertFalse(disconnected.snapshot.connected)
    }

    @Test fun realLevelIsSmoothedAndStaleCaptureLevelsIgnored() {
        val store = ready()
        val token = capture(store)
        store.level(token, 0.1f, 1010)
        val loud = store.snapshot().level
        assertTrue(loud in 0f..1f && loud > 0f)
        store.level("old", 1f, 1020)
        assertEquals(loud, store.snapshot().level)
        store.level(token, 0f, 1030)
        assertTrue(store.snapshot().level < loud && store.snapshot().level > 0f)
    }

    @Test fun emptyAudioShowsOnlyToastWithoutChangingDraft() {
        val store = ready()
        val token = capture(store)
        store.release(1500)
        val result = store.captureFinished(token, Base64.encode(ByteArray(0)), 1501)
        assertTrue(result.requests.isEmpty())
        assertEquals("idle", result.snapshot.phase)
        assertEquals(null, result.snapshot.error)
        assertEquals(null, result.snapshot.alertMessage)
        assertEquals(null, result.draftUpdate)
        assertEquals("未识别到人声", result.effects.single { it.action == "showToast" }.message)
        assertTrue(result.effects.any { it.action == "stopTicker" })
        assertFalse(result.effects.any { it.action == "focusEditor" })
    }

    @Test fun shortEnglishAudioIsSentWithoutDurationFilterAndDoesNotFocusEditor() {
        val store = ready()
        val token = capture(store)
        val stop = store.release(1100).effects.single { it.action == "stop" }
        assertEquals(200L, stop.delayMilliseconds)
        val result = store.captureFinished(token, Base64.encode(ByteArray(3200) { 1 }), 1300)
        assertTrue(
            result.requests
                .single()
                .payload
                .contains("\"language\":\"auto\""),
        )
        val completed = store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"Hello"}""")
        assertEquals("Hello", completed.draftUpdate)
        assertFalse(completed.snapshot.keyboardVisible)
        assertFalse(completed.effects.any { it.action == "focusEditor" })
    }

    @Test fun releaseDuringHardwareStartRetainsBufferedAudioUntilTailFinishes() {
        val store = ready()
        val token =
            store
                .press(1000)
                .effects
                .first { it.action == "permission" }
                .recordingId
        store.permissionResult(token, true, 1001)
        val released = store.release(1100)
        assertEquals("stopping", released.snapshot.phase)
        assertFalse(released.effects.any { it.action == "stop" && it.discard })
        val stop = store.captureStarted(token, 1101).effects.single { it.action == "stop" }
        assertFalse(stop.discard)
        assertEquals(200L, stop.delayMilliseconds)
        assertEquals(1, store.captureFinished(token, Base64.encode(ByteArray(3200)), 1302).requests.size)
    }

    @Test fun speechSelectionDoesNotBreakGeneralWireDecoder() {
        assertEquals(
            "speech-state",
            GatewayWireDecoder
                .decode(
                    """{"kind":"speech-state","selection":{"providerId":"sensevoice-local","language":"zh"}}""",
                ).kind,
        )
    }

    @Test
    fun permissionDeniedStopsTickerAndNeverStartsHardware() {
        val store = ready()
        val press = store.press(1000)
        assertEquals("startTicker", press.effects.first().action)
        val token = press.effects.first { it.action == "permission" }.recordingId
        val denied = store.permissionResult(token, false, 1001)
        assertEquals("idle", denied.snapshot.phase)
        assertTrue(denied.effects.any { it.action == "stopTicker" })
        assertFalse(denied.effects.any { it.action == "start" })
    }

    @Test
    fun unrelatedUncorrelatedErrorDoesNotOverwriteIdleState() {
        val store = ready()
        store.acceptJson("""{"kind":"error","message":"unrelated"}""")
        assertEquals(null, store.snapshot().error)
        assertTrue(store.snapshot().ready)
    }

    @Test
    fun officialServiceWithdrawalDiscardsOwnedRecording() {
        val store = SharedVoiceInputStore()
        val opening = store.connectionChanged(true, true)
        val watch = opening.requests.first { it.requestType == "speech-subscribe" }.correlationId
        store.acceptJson(
            """{"kind":"speech-state","requestId":"$watch","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}""",
        )
        val token = capture(store)
        val closed = store.acceptJson("""{"kind":"error","requestId":"$watch","message":"plugin closed"}""")
        assertFalse(closed.snapshot.ready)
        assertFalse(closed.snapshot.active)
        assertTrue(closed.effects.any { it.recordingId == token && it.discard })
    }

    @Test
    fun lateCatalogCannotReplaceNewerSubscribedPreparationState() {
        val store = SharedVoiceInputStore()
        val opening = store.connectionChanged(true, true)
        val catalog = opening.requests.first { it.requestType == "speech-catalog" }.correlationId
        val watch = opening.requests.first { it.requestType == "speech-subscribe" }.correlationId
        store.acceptJson(
            """{"kind":"speech-state","requestId":"$watch","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}""",
        )
        store.acceptJson("""{"kind":"speech-catalog","requestId":"$catalog","available":false}""")
        assertTrue(store.snapshot().ready)
    }

    @Test
    fun audioWindowBeyondPublishedLimitIsClippedBeforeSending() {
        val store = SharedVoiceInputStore()
        val request = store.connectionChanged(true, true).requests.first { it.requestType == "speech-catalog" }
        store.acceptJson(
            """{"kind":"speech-catalog","requestId":"${request.correlationId}","available":true,"maxDurationSeconds":1,"maxAudioBytes":32044,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}""",
        )
        val token = capture(store)
        store.tick(2002)
        assertEquals("stopping", store.snapshot().phase)
        val result = store.captureFinished(token, Base64.encode(ByteArray(33600)), 2003)
        assertEquals(1.0, result.snapshot.recordingSeconds)
        val encoded = Regex("\"audioBase64\":\"([^\"]+)\"").find(result.requests.single().payload)!!.groupValues[1]
        assertEquals(32044, Base64.decode(encoded).size)
    }

    @Test
    fun pendingTranscriptCannotFollowUserIntoAnotherSession() {
        val store = ready()
        val token = transcribe(store)
        store.draftChanged("edited")
        store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"pending"}""")
        assertNotNull(store.snapshot().pendingTranscript)
        assertEquals(null, store.open("another-session", "").snapshot.pendingTranscript)
    }

    @Test
    fun unsupportedGatewayOnlyPresentsDesktopSetupAlert() {
        val store = SharedVoiceInputStore()
        store.open("session-1", "原草稿")
        store.connectionChanged(true, false)
        val rejected = store.press(1000)
        assertEquals("idle", rejected.snapshot.phase)
        assertEquals(null, rejected.draftUpdate)
        assertEquals(null, rejected.snapshot.error)
        assertTrue(rejected.effects.isEmpty())
        assertTrue(rejected.requests.isEmpty())
        assertTrue(
            rejected.snapshot.alertMessage
                .orEmpty()
                .contains("升级移动网关"),
        )
        assertTrue(
            rejected.snapshot.alertMessage
                .orEmpty()
                .contains("桌面端"),
        )
        assertTrue(
            rejected.snapshot.alertMessage
                .orEmpty()
                .contains("初始化"),
        )
        assertEquals(null, store.dismissAlert().snapshot.alertMessage)
    }

    @Test
    fun successfulTranscriptAndPendingInsertionNeverRequestEditorFocus() {
        val store = ready()
        var token = transcribe(store)
        val success = store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"语音文字"}""")
        assertEquals("语音文字", success.draftUpdate)
        assertFalse(success.effects.any { it.action == "focusEditor" })
        assertFalse(success.snapshot.keyboardVisible)
        token = transcribe(store)
        store.draftChanged("修改后的草稿")
        val conflict = store.acceptJson("""{"kind":"speech-transcript","requestId":"$token","text":"另外一段"}""")
        assertFalse(conflict.effects.any { it.action == "focusEditor" })
        val insertion = store.insertPending()
        assertEquals("修改后的草稿\n另外一段", insertion.draftUpdate)
        assertFalse(insertion.effects.any { it.action == "focusEditor" })
        assertFalse(insertion.snapshot.keyboardVisible)
    }

    @Test
    fun waveformHistoryUsesRealLevelsAndStaysGatheredOnSilence() {
        val store = ready()
        val token = capture(store)
        repeat(50) { store.level(token, 0.15f, 1010L + it * 40) }
        assertEquals(45, store.snapshot().waveformLevels.size)
        assertTrue(store.snapshot().waveformLevels.all { it > 0f })
        assertEquals(1f, store.snapshot().visualActivity)
        repeat(60) { store.level(token, 0f, 3010L + it * 40) }
        store.tick(10000)
        assertEquals("recording", store.snapshot().phase)
        assertEquals(1f, store.snapshot().visualActivity)
        assertTrue(store.snapshot().waveformLevels.last() < 0.001f)
    }

    @Test
    fun briefQuietSoundCompletesGatheringWithoutFurtherSpeech() {
        val store = ready()
        val token = capture(store)
        store.level(token, 0.004f, 1010)
        assertTrue(store.snapshot().level < 0.08f)
        assertEquals(1f, store.snapshot().visualActivity)
        // 即使下一帧已经静音，目标仍保持完整波形，足够完成两端 160ms 的聚拢动画。
        store.level(token, 0f, 1050)
        store.tick(1210)
        assertEquals(1f, store.snapshot().visualActivity)
        store.tick(1609)
        assertEquals(1f, store.snapshot().visualActivity)
        store.tick(10000)
        assertEquals(1f, store.snapshot().visualActivity)
        assertEquals("recording", store.snapshot().phase)
    }

    @Test
    fun speechPausesKeepWaveformWhileRealLevelsContinueChanging() {
        val store = ready()
        val token = capture(store)
        store.level(token, 0.1f, 1010)
        val firstLevel = store.snapshot().level
        store.level(token, 0f, 1300)
        assertTrue(store.snapshot().level < firstLevel)
        assertEquals(1f, store.snapshot().visualActivity)
        store.level(token, 0.2f, 1500)
        assertTrue(store.snapshot().level > firstLevel)
        store.tick(2099)
        assertEquals(1f, store.snapshot().visualActivity)
        store.level(token, 0f, 2100)
        store.tick(10000)
        assertEquals(1f, store.snapshot().visualActivity)
        store.pointerMoved(-100f)
        assertEquals(1f, store.snapshot().visualActivity)
        store.pointerMoved(0f)
        assertEquals(1f, store.snapshot().visualActivity)
        store.release(10001)
        assertEquals(0f, store.snapshot().visualActivity)
    }

    @Test
    fun pauseDoesNotStopCaptureAndFinalPcmIsSubmittedTogether() {
        val store = ready()
        val token = capture(store)
        store.level(token, 0.1f, 1010)
        repeat(100) { index ->
            val silent = store.level(token, 0f, 1100L + index * 50)
            assertTrue(silent.effects.isEmpty())
            assertTrue(silent.requests.isEmpty())
        }
        val paused = store.tick(10000)
        assertEquals("recording", paused.snapshot.phase)
        assertTrue(paused.snapshot.waveformActive)
        assertTrue(paused.effects.isEmpty())
        assertTrue(paused.requests.isEmpty())
        store.level(token, 0.2f, 10100)
        val release = store.release(10200)
        val stop = release.effects.single { it.action == "stop" }
        assertFalse(stop.discard)
        assertEquals(200L, stop.delayMilliseconds)
        val pcm = ByteArray(32000)
        pcm[0] = 11
        pcm[pcm.lastIndex - 1] = 22
        pcm[pcm.lastIndex] = 33
        val request = store.captureFinished(token, Base64.encode(pcm), 10400).requests.single()
        val encoded = Regex("\"audioBase64\":\"([^\"]+)\"").find(request.payload)!!.groupValues[1]
        val wave = Base64.decode(encoded)
        assertTrue(wave.copyOfRange(44, 6444).all { it == 0.toByte() })
        assertTrue(wave.copyOfRange(6444, 6444 + pcm.size).contentEquals(pcm))
        assertTrue(wave.copyOfRange(6444 + pcm.size, wave.size).all { it == 0.toByte() })
    }

    @Test
    fun silenceInvalidSamplesAndStaleRecordingCannotTriggerGathering() {
        val store = ready()
        val token = capture(store)
        store.level(token, 0.001f, 1010)
        store.level(token, Float.NaN, 1020)
        store.level("old", 1f, 1030)
        assertEquals(0f, store.snapshot().visualActivity)
        store.level(token, 0.1f, 1040)
        store.cancel()
        val nextToken = capture(store)
        assertEquals(0f, store.snapshot().visualActivity)
        store.level(token, 1f, 1050)
        store.tick(1060)
        assertEquals(0f, store.snapshot().visualActivity)
        store.level(nextToken, 0.1f, 1070)
        store.release(1080)
        assertEquals(0f, store.snapshot().visualActivity)
    }

    @Test
    fun emptyTranscriptShowsToastOnceWithoutAlertOrFocusChange() {
        val store = ready("保留草稿")
        val token = transcribe(store)
        val response = """{"kind":"speech-transcript","requestId":"$token","text":"  "}"""
        val result = store.acceptJson(response)
        assertEquals("idle", result.snapshot.phase)
        assertEquals(null, result.snapshot.alertMessage)
        assertEquals(null, result.snapshot.error)
        assertEquals(null, result.draftUpdate)
        assertTrue(result.requests.isEmpty())
        assertEquals("未识别到人声", result.effects.single { it.action == "showToast" }.message)
        assertFalse(result.effects.any { it.action == "focusEditor" })
        assertTrue(store.acceptJson(response).effects.isEmpty())
        val nextToken = transcribe(store)
        val next = store.acceptJson("""{"kind":"speech-transcript","requestId":"$nextToken","text":"新文字"}""")
        assertEquals("保留草稿\n新文字", next.draftUpdate)
    }

    @Test
    fun invalidAudioAndPermissionErrorsStillUseAlerts() {
        val store = ready()
        val token = capture(store)
        store.release(1500)
        val invalid = store.captureFinished(token, "not-base64!", 1501)
        assertNotNull(invalid.snapshot.alertMessage)
        assertFalse(invalid.effects.any { it.action == "showToast" })
        val press = store.press(2000)
        val denied = store.permissionResult(press.effects.first { it.action == "permission" }.recordingId, false, 2001)
        assertNotNull(denied.snapshot.alertMessage)
        assertFalse(denied.effects.any { it.action == "showToast" })
    }

    @Test
    fun hapticStartCoincidesWithOverlayAndDoesNotRepeatOnCaptureStart() {
        val store = ready()
        val press = store.press(1000)
        assertTrue(press.snapshot.active)
        assertEquals(1, press.effects.count { it.action == "hapticStart" })
        assertFalse(store.press(1001).effects.any { it.action.startsWith("haptic") })
        val token = press.effects.first { it.action == "permission" }.recordingId
        assertFalse(store.permissionResult(token, true, 1002).effects.any { it.action.startsWith("haptic") })
        assertFalse(store.captureStarted(token, 1003).effects.any { it.action.startsWith("haptic") })
        store.cancel()
        store.connectionChanged(true, false)
        assertFalse(store.press(2000).effects.any { it.action.startsWith("haptic") })
    }

    @Test
    fun cancelHapticOnlyOccursWhenCrossingIntoCancelRegion() {
        val store = ready()
        capture(store)
        assertTrue(store.pointerMoved(-64f).effects.isEmpty())
        assertEquals(
            "hapticCancel",
            store
                .pointerMoved(-65f)
                .effects
                .single()
                .action,
        )
        assertTrue(store.pointerMoved(-90f).effects.isEmpty())
        assertTrue(store.pointerMoved(0f).effects.isEmpty())
        assertEquals(
            "hapticCancel",
            store
                .pointerMoved(-80f)
                .effects
                .single()
                .action,
        )
        store.release(1500)
        assertTrue(store.pointerMoved(-90f).effects.isEmpty())
    }

    @Test
    fun releaseHapticOccursOnceForBothTranscriptionAndSwipeCancellation() {
        val store = ready()
        capture(store)
        val release = store.release(1500)
        assertEquals(1, release.effects.count { it.action == "hapticRelease" })
        assertTrue(release.effects.any { it.action == "stop" && !it.discard })
        assertTrue(store.release(1501).effects.isEmpty())
        store.cancel()
        capture(store)
        store.pointerMoved(-90f)
        val cancel = store.release(1500)
        assertEquals(1, cancel.effects.count { it.action == "hapticRelease" })
        assertTrue(cancel.effects.any { it.action == "stop" && it.discard })
        assertTrue(store.release(1501).effects.isEmpty())
    }

    @Test
    fun releaseBeforePermissionStillHasFeedbackButAutomaticStopsAreSilent() {
        val store = ready()
        store.press(1000)
        assertEquals(1, store.release(1001).effects.count { it.action == "hapticRelease" })
        assertTrue(store.release(1002).effects.isEmpty())
        capture(store)
        val automatic = store.tick(121002)
        assertEquals("stopping", automatic.snapshot.phase)
        assertFalse(automatic.effects.any { it.action.startsWith("haptic") })
        assertFalse(store.cancel().effects.any { it.action.startsWith("haptic") })
    }
}
