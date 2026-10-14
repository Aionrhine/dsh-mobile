package com.clarklevis.dsh.android.platform

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.shared.facade.SharedVoiceInputStore
import com.clarklevis.dsh.shared.gateway.GatewayRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.io.encoding.Base64

/** 仅替换硬件接口，不申请权限或读取真实麦克风；验证平台回调与共享状态机的顺序。 */
class VoiceCaptureReadinessDeviceTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test
    fun authorizedDownPreCapturesAndPreservesFirstSamplesForTranscription() {
        val hardware = FakeCapture()
        val sent = mutableListOf<GatewayRequest>()
        lateinit var adapter: AndroidVoiceInputAdapter
        instrumentation.runOnMainSync {
            adapter = AndroidVoiceInputAdapter(context(), sent::add, readyStore(), hardware)
            adapter.resumeCapture()
            assertEquals(1, hardware.preparations)
            assertEquals(0, hardware.starts)
            adapter.touchDown(SystemClock.uptimeMillis())
            assertEquals(1, hardware.starts)
            assertFalse(adapter.state.overlayVisible)
            hardware.hardwareStarted()
            assertFalse(adapter.state.overlayVisible)
            adapter.press()
            assertEquals(1, hardware.starts)
            assertTrue(adapter.state.overlayVisible)
            assertFalse(adapter.state.waveformActive)
            adapter.release()
            assertFalse(adapter.state.overlayVisible)
        }
        assertTrue(hardware.stopped.await(2, TimeUnit.SECONDS))
        instrumentation.runOnMainSync {
            val request = sent.single { it.requestType == "speech-transcribe" }
            val encoded = Regex("\"audioBase64\":\"([^\"]+)\"").find(request.payload)!!.groupValues[1]
            val wave = Base64.decode(encoded)
            assertTrue(wave.copyOfRange(6444, 6444 + hardware.pcm.size).contentEquals(hardware.pcm))
            assertEquals("transcribing", adapter.state.phase)
            assertFalse(adapter.state.overlayVisible)
            adapter.leave()
        }
    }

    @Test
    fun shortTapDiscardsPreCaptureAndLateReadyCannotDisplayOverlay() {
        val hardware = FakeCapture()
        val sent = mutableListOf<GatewayRequest>()
        instrumentation.runOnMainSync {
            val adapter = AndroidVoiceInputAdapter(context(), sent::add, readyStore(), hardware)
            adapter.touchDown(SystemClock.uptimeMillis())
            assertEquals(1, hardware.starts)
            adapter.touchFinished()
            assertTrue(hardware.discarded)
            hardware.hardwareStarted()
            assertFalse(adapter.state.active)
            assertFalse(adapter.state.overlayVisible)
            assertTrue(sent.isEmpty())
            adapter.leave()
        }
    }

    @Test
    fun holdSwipeAndReleaseDeliverThreeHapticCuesWithoutWaitingForHardware() {
        val hardware = FakeCapture()
        val cues = mutableListOf<String>()
        instrumentation.runOnMainSync {
            val adapter = AndroidVoiceInputAdapter(context(), {}, readyStore(), hardware)
            adapter.onHapticFeedback = cues::add
            adapter.touchDown(SystemClock.uptimeMillis())
            assertTrue(cues.isEmpty())
            adapter.press()
            assertEquals("starting", adapter.state.phase)
            assertEquals(listOf("hapticStart"), cues)
            adapter.press()
            hardware.hardwareStarted()
            hardware.hardwareStarted()
            assertEquals(listOf("hapticStart"), cues)
            adapter.move(-70f)
            adapter.move(-90f)
            adapter.release()
            adapter.release()
            assertEquals(listOf("hapticStart", "hapticCancel", "hapticRelease"), cues)
            assertTrue(hardware.discarded)
            adapter.leave()
        }
    }

    private fun context(): Context =
        object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
            override fun checkPermission(
                permission: String,
                pid: Int,
                uid: Int,
            ): Int =
                if (permission ==
                    Manifest.permission.RECORD_AUDIO
                ) {
                    PackageManager.PERMISSION_GRANTED
                } else {
                    super.checkPermission(permission, pid, uid)
                }

            override fun checkSelfPermission(permission: String): Int =
                if (permission ==
                    Manifest.permission.RECORD_AUDIO
                ) {
                    PackageManager.PERMISSION_GRANTED
                } else {
                    super.checkSelfPermission(permission)
                }
        }

    private fun readyStore(): SharedVoiceInputStore =
        SharedVoiceInputStore().apply {
            open("capture", "")
            val catalog = connectionChanged(true, true).requests.first { it.requestType == "speech-catalog" }.correlationId
            acceptJson(
                """{"kind":"speech-catalog","requestId":"$catalog","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}""",
            )
        }

    private class FakeCapture : AndroidVoiceAudioCapturing {
        var preparations = 0
        var starts = 0
        var discarded = false
        val stopped = CountDownLatch(1)
        val pcm =
            ByteArray(3200).also {
                it[0] = 48
                it[1] = 117
            }
        private var token: String? = null
        private var ready: (() -> Unit)? = null
        private var level: ((Float) -> Unit)? = null
        private var finished: ((String) -> Unit)? = null

        override fun prepare() {
            preparations++
        }

        override fun release() {}

        override fun start(
            id: String,
            started: () -> Unit,
            level: (Float) -> Unit,
            finished: (String) -> Unit,
            failure: () -> Unit,
        ) {
            starts++
            token = id
            ready = started
            this.level = level
            this.finished = finished
        }

        fun hardwareStarted() {
            ready?.invoke()
        }

        override fun stop(
            id: String,
            discard: Boolean,
        ) {
            if (token != id) return
            token = null
            discarded = discard
            if (!discard) finished?.invoke(Base64.encode(pcm))
            stopped.countDown()
        }
    }
}
