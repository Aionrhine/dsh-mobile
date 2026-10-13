package com.clarklevis.dsh.shared

import com.clarklevis.dsh.shared.facade.VoiceAudioFormat
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class VoiceRecognitionAudioTest {
    @Test
    fun contextPreservesEveryRecordedSampleAndAddsOnlySilence() {
        val pcm = samples(12000, -16000, 32767, -32768)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, 32000)
        assertEquals(6400 + pcm.size + 16000, prepared.size)
        assertTrue(prepared.take(6400).all { it == 0.toByte() })
        assertContentEquals(pcm, prepared.copyOfRange(6400, 6400 + pcm.size))
        assertTrue(prepared.drop(6400 + pcm.size).all { it == 0.toByte() })
    }

    @Test
    fun quietAudioGetsOneBoundedGainWithoutClipping() {
        val pcm = samples(500, -500, 250, -250, 0) + ByteArray(40)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, 32000)
        assertContentEquals(samples(4000, -4000, 2000, -2000, 0) + ByteArray(40), prepared.copyOfRange(6400, 6400 + pcm.size))
    }

    @Test
    fun moderateAudioGainStopsAtTargetPeak() {
        val pcm = samples(4000, -4000, 1000, -1000) + ByteArray(48)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, 32000)
        assertContentEquals(samples(16384, -16384, 4096, -4096) + ByteArray(48), prepared.copyOfRange(6400, 6400 + pcm.size))
    }

    @Test
    fun continuousLowLevelNoiseIsNotAmplified() {
        val pcm = samples(500, -500, 500, -500, 500, -500) + ByteArray(2)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, 32000)
        assertContentEquals(pcm, prepared.copyOfRange(6400, 6400 + pcm.size))
    }

    @Test
    fun silenceAndNearZeroInputAreNeverAmplified() {
        val pcm = samples(0, 1, -1, 127, -127)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, 32000)
        assertContentEquals(pcm, prepared.copyOfRange(6400, 6400 + pcm.size))
        assertTrue(VoiceAudioFormat.prepareRecognitionPcm(ByteArray(3200), 32000).all { it == 0.toByte() })
    }

    @Test
    fun contextNeverExceedsPublishedLimitOrRemovesRecordedTail() {
        val pcm = samples(12000, -16000, 32767, -32768)
        val prepared = VoiceAudioFormat.prepareRecognitionPcm(pcm, pcm.size + 11)
        assertEquals(pcm.size + 10, prepared.size)
        assertContentEquals(pcm, prepared.copyOfRange(10, prepared.size))
        assertContentEquals(pcm, VoiceAudioFormat.prepareRecognitionPcm(pcm, pcm.size))
    }

    @Suppress("MagicNumber")
    private fun samples(vararg values: Int): ByteArray =
        ByteArray(values.size * 2).also { bytes ->
            values.forEachIndexed { index, value ->
                bytes[index * 2] = value.toByte()
                bytes[index * 2 + 1] = (value shr 8).toByte()
            }
        }
}
