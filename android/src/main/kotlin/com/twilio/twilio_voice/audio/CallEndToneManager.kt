package com.twilio.twilio_voice.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Manages call-end tone playback.
 * Plays a short tone when the final call ends to inform the user.
 * Supports speaker, earpiece, and Bluetooth audio routing.
 * The tone plays once (not looped) and cleans up automatically.
 */
class CallEndToneManager(private val context: Context) {

    companion object {
        private const val TAG = "CallEndToneManager"

        @Volatile
        private var instance: CallEndToneManager? = null

        fun getInstance(context: Context): CallEndToneManager {
            return instance ?: synchronized(this) {
                instance ?: CallEndToneManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private var mediaPlayer: MediaPlayer? = null
    private var isPlaying: Boolean = false
    private val audioManager: AudioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Plays the call-end tone once.
     * Respects the current audio route (speaker/bluetooth/earpiece).
     * @param useSpeaker Whether to play through speaker
     * @param useBluetooth Whether to play through Bluetooth
     */
    @Synchronized
    fun playCallEndTone(useSpeaker: Boolean = false, useBluetooth: Boolean = false) {
        if (isPlaying) {
            Log.d(TAG, "Call end tone already playing")
            return
        }

        try {
            val resId = getCallEndResourceId()
            if (resId == 0) {
                Log.e(TAG, "Call end audio file not found (call_end.mp3 in res/raw/)")
                return
            }

            mediaPlayer = MediaPlayer.create(context, resId)?.apply {
                isLooping = false // Play once only

                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )

                setOnErrorListener { _, what, extra ->
                    Log.e(TAG, "MediaPlayer error: what=$what, extra=$extra")
                    stopCallEndTone()
                    true
                }

                setOnCompletionListener {
                    Log.d(TAG, "Call end tone finished playing")
                    stopCallEndTone()
                }
            }

            if (mediaPlayer == null) {
                Log.e(TAG, "Failed to create MediaPlayer for call end tone")
                return
            }

            // Configure audio routing before playing
            configureAudioRouting(useSpeaker, useBluetooth)

            mediaPlayer?.start()
            isPlaying = true
            Log.d(TAG, "Started call end tone, speaker: $useSpeaker, bluetooth: $useBluetooth")

        } catch (e: Exception) {
            Log.e(TAG, "Failed to start call end tone: ${e.message}")
            stopCallEndTone()
        }
    }

    /**
     * Stops the call-end tone and releases resources.
     */
    @Synchronized
    fun stopCallEndTone() {
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
            Log.e(TAG, "Error stopping call end tone: ${e.message}")
        } finally {
            mediaPlayer = null
            isPlaying = false
            Log.d(TAG, "Stopped call end tone")
        }
    }

    /**
     * Returns whether the call-end tone is currently playing.
     */
    fun isCallEndTonePlaying(): Boolean = isPlaying

    /**
     * Configures audio routing for playback based on desired state.
     * Priority: Bluetooth > Speaker > Earpiece
     */
    private fun configureAudioRouting(useSpeaker: Boolean, useBluetooth: Boolean) {
        try {
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

            when {
                useBluetooth -> {
                    audioManager.isSpeakerphoneOn = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val availableDevices = audioManager.availableCommunicationDevices
                            val bluetoothDevice = availableDevices.firstOrNull {
                                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                                it.type == AudioDeviceInfo.TYPE_BLE_HEADSET ||
                                it.type == AudioDeviceInfo.TYPE_HEARING_AID ||
                                it.type == AudioDeviceInfo.TYPE_BLE_SPEAKER
                            }
                            if (bluetoothDevice != null) {
                                audioManager.setCommunicationDevice(bluetoothDevice)
                                Log.d(TAG, "Audio routed to Bluetooth via setCommunicationDevice")
                            } else {
                                audioManager.startBluetoothSco()
                                audioManager.isBluetoothScoOn = true
                                Log.d(TAG, "Audio routed to Bluetooth via legacy SCO")
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to route to Bluetooth: ${e.message}")
                            audioManager.startBluetoothSco()
                            audioManager.isBluetoothScoOn = true
                        }
                    } else {
                        audioManager.startBluetoothSco()
                        audioManager.isBluetoothScoOn = true
                        Log.d(TAG, "Audio routed to Bluetooth via legacy SCO")
                    }
                }
                useSpeaker -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            audioManager.clearCommunicationDevice()
                            val availableDevices = audioManager.availableCommunicationDevices
                            val speakerDevice = availableDevices.firstOrNull {
                                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                            }
                            if (speakerDevice != null) {
                                audioManager.setCommunicationDevice(speakerDevice)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to route to speaker: ${e.message}")
                        }
                    }
                    audioManager.isSpeakerphoneOn = true
                    Log.d(TAG, "Audio routed to speaker")
                }
                else -> {
                    audioManager.isSpeakerphoneOn = false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            audioManager.clearCommunicationDevice()
                            val availableDevices = audioManager.availableCommunicationDevices
                            val earpieceDevice = availableDevices.firstOrNull {
                                it.type == AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
                            }
                            if (earpieceDevice != null) {
                                audioManager.setCommunicationDevice(earpieceDevice)
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to route to earpiece: ${e.message}")
                        }
                    }
                    Log.d(TAG, "Audio routed to earpiece")
                }
            }

            Log.d(TAG, "Audio routing configured: speaker=$useSpeaker, bluetooth=$useBluetooth, mode=${audioManager.mode}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to configure audio routing: ${e.message}")
        }
    }

    /**
     * Finds the call_end audio resource ID in raw resources.
     */
    private fun getCallEndResourceId(): Int {
        val resId = context.resources.getIdentifier("call_end", "raw", context.packageName)
        if (resId != 0) {
            Log.d(TAG, "Found call_end in raw resources")
            return resId
        }

        Log.w(TAG, "No call_end audio file found. Please add call_end.mp3 to res/raw/")
        return 0
    }

    /**
     * Cleans up resources. Call this when the manager is no longer needed.
     */
    fun release() {
        stopCallEndTone()
        instance = null
    }
}
