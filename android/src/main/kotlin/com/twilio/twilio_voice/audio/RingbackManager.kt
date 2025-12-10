package com.twilio.twilio_voice.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.util.Log
import com.twilio.twilio_voice.R

/**
 * Manages ringback tone playback for outgoing calls.
 * The ringback tone plays when the callee's phone is ringing (before they answer).
 */
class RingbackManager(private val context: Context) {

    companion object {
        private const val TAG = "RingbackManager"
        
        @Volatile
        private var instance: RingbackManager? = null
        
        fun getInstance(context: Context): RingbackManager {
            return instance ?: synchronized(this) {
                instance ?: RingbackManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private var mediaPlayer: MediaPlayer? = null
    private var isPlaying: Boolean = false
    private var desiredSpeakerState: Boolean = false
    private val audioManager: AudioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /**
     * Starts playing the ringback tone.
     * @param useSpeaker Whether to play through speaker (true) or earpiece (false)
     */
    @Synchronized
    fun startRingback(useSpeaker: Boolean = false) {
        if (isPlaying) {
            Log.d(TAG, "Ringback already playing")
            return
        }

        desiredSpeakerState = useSpeaker

        try {
            // Try to find the ringback audio file
            val resId = getRingbackResourceId()
            if (resId == 0) {
                Log.e(TAG, "Ringback audio file not found")
                return
            }

            mediaPlayer = MediaPlayer.create(context, resId)?.apply {
                isLooping = true
                
                // Set audio attributes for voice call
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )

                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "MediaPlayer error: what=$what, extra=$extra")
                    stopRingback()
                    true
                }

                setOnCompletionListener {
                    // Should not be called since we loop, but handle just in case
                    Log.d(TAG, "MediaPlayer completed unexpectedly")
                }
            }

            // Configure audio routing before playing
            configureAudioRouting(useSpeaker)

            mediaPlayer?.start()
            isPlaying = true
            Log.d(TAG, "Started ringback tone, speaker: $useSpeaker")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start ringback: ${e.message}")
            stopRingback()
        }
    }

    /**
     * Stops the ringback tone.
     */
    @Synchronized
    fun stopRingback() {
        if (!isPlaying && mediaPlayer == null) {
            return
        }

        try {
            mediaPlayer?.apply {
                if (isPlaying) {
                    stop()
                }
                reset()
                release()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping ringback: ${e.message}")
        } finally {
            mediaPlayer = null
            isPlaying = false
            Log.d(TAG, "Stopped ringback tone")
        }
    }

    /**
     * Updates the audio routing when speaker state changes.
     * @param useSpeaker Whether to route audio to speaker (true) or earpiece (false)
     */
    @Synchronized
    fun updateAudioRoute(useSpeaker: Boolean) {
        desiredSpeakerState = useSpeaker
        
        if (!isPlaying) {
            Log.d(TAG, "Not playing, storing speaker preference: $useSpeaker")
            return
        }

        configureAudioRouting(useSpeaker)
        Log.d(TAG, "Updated ringback audio route, speaker: $useSpeaker")
    }

    /**
     * Returns whether ringback is currently playing.
     */
    fun isRingbackPlaying(): Boolean = isPlaying

    /**
     * Returns the current speaker state preference.
     */
    fun isSpeakerOn(): Boolean = desiredSpeakerState

    /**
     * Configures audio routing for ringback playback.
     */
    private fun configureAudioRouting(useSpeaker: Boolean) {
        try {
            // Set mode for voice communication
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            
            // Toggle speaker
            audioManager.isSpeakerphoneOn = useSpeaker
            
            Log.d(TAG, "Audio routing configured: speaker=$useSpeaker, mode=${audioManager.mode}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure audio routing: ${e.message}")
        }
    }

    /**
     * Finds the ringback audio resource ID.
     * First looks for a custom ringback.mp3/wav in raw resources,
     * then falls back to a default tone if available.
     */
    private fun getRingbackResourceId(): Int {
        // Try to find ringback in raw resources
        val resId = context.resources.getIdentifier("ringback", "raw", context.packageName)
        if (resId != 0) {
            Log.d(TAG, "Found ringback in raw resources")
            return resId
        }

        // Try alternative names
        val alternativeNames = listOf("ringback_tone", "ring_back", "outgoing_ring")
        for (name in alternativeNames) {
            val altResId = context.resources.getIdentifier(name, "raw", context.packageName)
            if (altResId != 0) {
                Log.d(TAG, "Found ringback with alternative name: $name")
                return altResId
            }
        }

        Log.w(TAG, "No ringback audio file found. Please add ringback.mp3 or ringback.wav to res/raw/")
        return 0
    }

    /**
     * Cleans up resources. Call this when the manager is no longer needed.
     */
    fun release() {
        stopRingback()
        instance = null
    }
}
