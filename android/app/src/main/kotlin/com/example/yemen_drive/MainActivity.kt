package com.example.yemen_drive_driver

import com.yemendrive.otp.OtpSmsBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {
    private var otpSms: OtpSmsBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        otpSms?.dispose()
        otpSms = OtpSmsBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "yemendrive/chat_sound")
            .setMethodCallHandler { call, result ->
                if (call.method != "playIncoming") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    if (audio.ringerMode == AudioManager.RINGER_MODE_NORMAL &&
                        audio.getStreamVolume(AudioManager.STREAM_NOTIFICATION) > 0) {
                        val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 65)
                        tone.startTone(ToneGenerator.TONE_PROP_ACK, 110)
                        Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 250)
                    }
                    result.success(null)
                } catch (_: Exception) {
                    result.success(null)
                }
            }
    }
    override fun onDestroy() {
        otpSms?.dispose(); otpSms = null
        super.onDestroy()
    }
}
