package com.clarklevis.dsh.android.ui

import android.Manifest
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.PackageManager
import android.os.SystemClock
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.clarklevis.dsh.android.AndroidSharedStateHolder
import com.clarklevis.dsh.shared.facade.SharedVoiceInputStore
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicLong

/** 使用真实 MotionEvent 和系统时钟测量，权限回调保持等待，不打开麦克风或远端连接。 */
class VoiceInputLatencyDeviceTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun touchToOverlayDoesNotWaitForMicrophoneOrOneSecond() {
        val shared = SharedVoiceInputStore()
        shared.open("latency", "")
        val request = shared.connectionChanged(true, true).requests.first { it.requestType == "speech-catalog" }
        shared.acceptJson(
            """{"kind":"speech-catalog","requestId":"${request.correlationId}","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}""",
        )
        val context =
            object : ContextWrapper(ApplicationProvider.getApplicationContext<Context>()) {
                override fun checkPermission(
                    permission: String,
                    pid: Int,
                    uid: Int,
                ): Int =
                    if (permission == Manifest.permission.RECORD_AUDIO) {
                        PackageManager.PERMISSION_DENIED
                    } else {
                        super.checkPermission(permission, pid, uid)
                    }
            }
        val holder =
            AndroidSharedStateHolder(voiceStore = shared, voiceContext = context).apply {
                wirePayload =
                    """{"kind":"sessions","items":[{"sessionId":"latency","updatedAt":1786937352000,"running":false,"blank":false,"cwd":"/tmp/latency","agentPreset":"standard"}]}"""
                submitWirePayload()
                selectSession("latency")
                repeat(14) { index ->
                    wirePayload =
                        """{"kind":"event","sessionId":"latency","seq":${index + 1},"time":${1786937353 + index},"event":{"type":"user/message","source":"user","text":"${"真实会话延迟测量".repeat(
                            8,
                        )}"}}"""
                    submitWirePayload()
                }
            }
        val voice = holder.voiceInput
        val permissionAt = AtomicLong()
        val drawAt = AtomicLong()
        lateinit var view: View
        compose.setContent {
            view = LocalView.current
            DshTheme { ConversationScreen(holder, {}, {}) }
        }
        val drawListener =
            ViewTreeObserver.OnDrawListener {
                if (voice.state.active) drawAt.compareAndSet(0, SystemClock.uptimeMillis())
            }
        compose.runOnIdle {
            // 仅替换权限硬件回调；真实页面、手势、状态机、触感和蒙层渲染都保留。
            voice.onPermissionNeeded = { permissionAt.compareAndSet(0, SystemClock.uptimeMillis()) }
            view.viewTreeObserver.addOnDrawListener(drawListener)
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val position =
            compose
                .onNodeWithTag("composer-input")
                .fetchSemanticsNode()
                .boundsInRoot.center
        val location = IntArray(2)
        compose.runOnIdle { view.getLocationOnScreen(location) }
        val downAt = SystemClock.uptimeMillis()

        fun send(action: Int) {
            val event =
                MotionEvent.obtain(
                    downAt,
                    SystemClock.uptimeMillis(),
                    action,
                    position.x + location[0],
                    position.y + location[1],
                    0,
                )
            try {
                instrumentation.sendPointerSync(event)
            } finally {
                event.recycle()
            }
        }
        try {
            send(MotionEvent.ACTION_DOWN)
            compose.waitUntil(2_000) { drawAt.get() > 0 }
            compose.onNodeWithTag("voice-recording-overlay").assertExists()
            val recognized = permissionAt.get() - downAt
            val painted = drawAt.get() - downAt
            Log.i(
                "VoiceInputLatency",
                "touchToPermission=${recognized}ms touchToOverlayDraw=${painted}ms permissionStillPending=${voice.state.phase}",
            )
            assertTrue("长按识别不应等待一秒：${recognized}ms", recognized in 60..350)
            assertTrue("蒙层绘制不应等待权限或麦克风：${painted}ms", painted in 60..500)
            assertTrue(voice.state.phase == "authorizing")
        } finally {
            send(MotionEvent.ACTION_UP)
            compose.runOnIdle {
                view.viewTreeObserver.removeOnDrawListener(drawListener)
                holder.close()
            }
        }
    }
}
