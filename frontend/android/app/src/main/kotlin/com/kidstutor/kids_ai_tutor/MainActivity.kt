package com.kidstutor.kids_ai_tutor

import android.accounts.AccountManager
import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

class MainActivity : FlutterActivity() {
    private val channelName = "com.kidstutor/tts_audio"
    private val pickAccountRequestCode = 9001
    private val pickPdfRequestCode = 9002
    private var mediaPlayer: MediaPlayer? = null
    private var audioTrack: AudioTrack? = null
    private var mp3Codec: MediaCodec? = null
    private val codecLock = Any()
    private var mp3SampleRate = 24000
    private var mp3ChannelCount = 1
    private var mp3PtsUs = 0L
    private var mp3StreamStartMs = 0L
    private var mp3FirstPcmLogged = false
    private val pcmExecutor = Executors.newSingleThreadExecutor()
    private val pcmSessionGen = AtomicInteger(0)
    private val totalPcmFramesWritten = AtomicLong(0L)
    private var pendingPcmFinishResult: MethodChannel.Result? = null
    private var pendingPlayWavResult: MethodChannel.Result? = null
    private var pendingAccountResult: MethodChannel.Result? = null
    private var pendingPdfResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playWav" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_PATH", "Audio path is empty", null)
                            return@setMethodCallHandler
                        }
                        val speed = call.argument<Double>("speed") ?: 1.0
                        val pitch = call.argument<Double>("pitch") ?: 1.0
                        stopPlayer()
                        try {
                            val player = MediaPlayer()
                            mediaPlayer = player
                            pendingPlayWavResult = result
                            player.setDataSource(path)
                            player.setOnCompletionListener {
                                val r = pendingPlayWavResult
                                pendingPlayWavResult = null
                                stopPlayer()
                                r?.success(true)
                            }
                            player.setOnErrorListener { _, what, extra ->
                                val r = pendingPlayWavResult
                                pendingPlayWavResult = null
                                stopPlayer()
                                r?.error("PLAY_ERROR", "MediaPlayer error $what/$extra", null)
                                true
                            }
                            player.prepare()
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                                (speed != 1.0 || pitch != 1.0)
                            ) {
                                try {
                                    player.playbackParams = player.playbackParams
                                        .setSpeed(speed.toFloat())
                                        .setPitch(pitch.toFloat())
                                } catch (_: Exception) {
                                }
                            }
                            player.start()
                        } catch (e: Exception) {
                            val r = pendingPlayWavResult
                            pendingPlayWavResult = null
                            stopPlayer()
                            r?.error("PLAY_EXCEPTION", e.message, null)
                        }
                    }
                    "startPcmStream" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                        stopPlayer()
                        try {
                            audioTrack = createAndStartAudioTrack(sampleRate, 1)
                            totalPcmFramesWritten.set(0L)
                            result.success(true)
                        } catch (e: Exception) {
                            stopPlayer()
                            result.error("PCM_START_ERROR", e.message, null)
                        }
                    }
                    "writePcmChunk" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val gen = pcmSessionGen.get()
                        val track = audioTrack
                        if (track == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        pcmExecutor.execute {
                            var offset = 0
                            while (offset < bytes.size && gen == pcmSessionGen.get()) {
                                val written = try {
                                    track.write(bytes, offset, bytes.size - offset)
                                } catch (_: Exception) {
                                    break
                                }
                                if (written <= 0) break
                                offset += written
                                totalPcmFramesWritten.addAndGet((written / 2).toLong())
                            }
                        }
                        result.success(true)
                    }
                    "finishPcmStream" -> {
                        val prev = pendingPcmFinishResult
                        pendingPcmFinishResult = null
                        prev?.success(true)

                        val gen = pcmSessionGen.get()
                        if (audioTrack == null) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingPcmFinishResult = result
                        pcmExecutor.execute {
                            awaitTrackDrainAndRelease(gen)
                        }
                    }
                    "startMp3Stream" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                        val channelCount = call.argument<Int>("channelCount") ?: 1
                        stopPlayer()
                        try {
                            synchronized(codecLock) {
                                val format = MediaFormat.createAudioFormat(
                                    MediaFormat.MIMETYPE_AUDIO_MPEG,
                                    sampleRate,
                                    channelCount
                                )
                                format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 32768)
                                val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_MPEG)
                                codec.configure(format, null, null, 0)
                                codec.start()
                                mp3Codec = codec
                                mp3SampleRate = sampleRate
                                mp3ChannelCount = channelCount
                                mp3PtsUs = 0L
                                mp3StreamStartMs = System.currentTimeMillis()
                                mp3FirstPcmLogged = false
                                audioTrack = createAndStartAudioTrack(sampleRate, channelCount)
                                totalPcmFramesWritten.set(0L)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            stopPlayer()
                            result.error("MP3_START_ERROR", e.message, null)
                        }
                    }
                    "writeMp3Chunk" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes == null || bytes.isEmpty()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val gen = pcmSessionGen.get()
                        pcmExecutor.execute {
                            synchronized(codecLock) {
                                if (gen != pcmSessionGen.get()) return@execute
                                val codec = mp3Codec ?: return@execute
                                try {
                                    var offset = 0
                                    while (offset < bytes.size && gen == pcmSessionGen.get()) {
                                        drainMp3CodecOutput(codec, gen, waitForEos = false)
                                        val inIdx = codec.dequeueInputBuffer(15_000L)
                                        if (inIdx >= 0) {
                                            val inBuf = codec.getInputBuffer(inIdx) ?: break
                                            inBuf.clear()
                                            val toWrite = minOf(bytes.size - offset, inBuf.capacity())
                                            inBuf.put(bytes, offset, toWrite)
                                            codec.queueInputBuffer(inIdx, 0, toWrite, mp3PtsUs, 0)
                                            mp3PtsUs += 24_000L
                                            offset += toWrite
                                        }
                                        drainMp3CodecOutput(codec, gen, waitForEos = false)
                                    }
                                } catch (_: Exception) {
                                }
                            }
                        }
                        result.success(true)
                    }
                    "finishMp3Stream" -> {
                        val prev = pendingPcmFinishResult
                        pendingPcmFinishResult = null
                        prev?.success(true)

                        val gen = pcmSessionGen.get()
                        if (mp3Codec == null && audioTrack == null) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingPcmFinishResult = result
                        pcmExecutor.execute {
                            synchronized(codecLock) {
                                val codec = mp3Codec
                                if (codec != null && gen == pcmSessionGen.get()) {
                                    try {
                                        var eosSent = false
                                        for (attempt in 0 until 25) {
                                            if (gen != pcmSessionGen.get()) break
                                            drainMp3CodecOutput(codec, gen, waitForEos = false)
                                            val inIdx = codec.dequeueInputBuffer(15_000L)
                                            if (inIdx >= 0) {
                                                codec.queueInputBuffer(
                                                    inIdx,
                                                    0,
                                                    0,
                                                    mp3PtsUs,
                                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                                )
                                                eosSent = true
                                                break
                                            }
                                        }
                                        if (eosSent && gen == pcmSessionGen.get()) {
                                            drainMp3CodecOutput(codec, gen, waitForEos = true)
                                        }
                                    } catch (_: Exception) {
                                    } finally {
                                        try {
                                            codec.stop()
                                        } catch (_: Exception) {
                                        }
                                        try {
                                            codec.release()
                                        } catch (_: Exception) {
                                        }
                                        mp3Codec = null
                                    }
                                }
                            }
                            awaitTrackDrainAndRelease(gen)
                        }
                    }
                    "stop" -> {
                        stopPlayer()
                        result.success(true)
                    }
                    "pickGoogleAccount" -> {
                        if (pendingAccountResult != null) {
                            result.error("BUSY", "Account picker already active", null)
                            return@setMethodCallHandler
                        }
                        pendingAccountResult = result
                        try {
                            @Suppress("DEPRECATION")
                            val intent = AccountManager.newChooseAccountIntent(
                                null,
                                null,
                                arrayOf("com.google"),
                                false,
                                null,
                                null,
                                null,
                                null
                            )
                            startActivityForResult(intent, pickAccountRequestCode)
                        } catch (e: Exception) {
                            pendingAccountResult = null
                            result.error("PICKER_ERROR", e.message, null)
                        }
                    }
                    "pickPdf" -> {
                        if (pendingPdfResult != null) {
                            result.error("BUSY", "File picker already active", null)
                            return@setMethodCallHandler
                        }
                        pendingPdfResult = result
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/pdf"
                            }
                            startActivityForResult(intent, pickPdfRequestCode)
                        } catch (e: Exception) {
                            pendingPdfResult = null
                            result.error("PDF_PICKER_ERROR", e.message, null)
                        }
                    }
                    "getAppDataDir" -> {
                        result.success(filesDir.absolutePath)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == pickAccountRequestCode) {
            val res = pendingAccountResult
            pendingAccountResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                val email = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
                res?.success(email)
            } else {
                res?.success(null)
            }
            return
        }

        if (requestCode == pickPdfRequestCode) {
            val res = pendingPdfResult
            pendingPdfResult = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                res?.success(null)
                return
            }
            try {
                val uri = data.data!!
                val displayName = resolveDisplayName(uri) ?: "lesson_${System.currentTimeMillis()}.pdf"
                val safeName = if (displayName.lowercase().endsWith(".pdf")) displayName else "$displayName.pdf"
                val outFile = File(cacheDir, "picked_${System.currentTimeMillis()}.pdf")

                contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(outFile).use { output ->
                        input.copyTo(output)
                    }
                } ?: throw IllegalStateException("Unable to read selected PDF file")

                res?.success(mapOf("name" to safeName, "path" to outFile.absolutePath))
            } catch (e: Exception) {
                res?.error("PDF_READ_ERROR", e.message, null)
            }
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) {
                        val name = cursor.getString(idx)
                        if (!name.isNullOrBlank()) return name
                    }
                }
            }
        } catch (_: Exception) {
        }
        return uri.lastPathSegment
    }

    private fun createAndStartAudioTrack(sampleRate: Int, channelCount: Int): AudioTrack {
        val channelMask = if (channelCount <= 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBuf * 2, 8192)
        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(sampleRate)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(channelMask)
                        .build()
                )
                .setBufferSizeInBytes(bufSize)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC,
                sampleRate,
                channelMask,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize,
                AudioTrack.MODE_STREAM
            )
        }
        track.play()
        return track
    }

    private fun drainMp3CodecOutput(codec: MediaCodec, gen: Int, waitForEos: Boolean) {
        val info = MediaCodec.BufferInfo()
        val drainStart = System.currentTimeMillis()
        while (gen == pcmSessionGen.get()) {
            if (waitForEos && System.currentTimeMillis() - drainStart > 2500L) {
                break
            }
            val outIdx = try {
                codec.dequeueOutputBuffer(info, if (waitForEos) 10_000L else 0L)
            } catch (_: Exception) {
                break
            }
            if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                try {
                    val fmt = codec.outputFormat
                    val outRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    val outCh = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    if (outRate != mp3SampleRate || outCh != mp3ChannelCount || audioTrack == null) {
                        mp3SampleRate = outRate
                        mp3ChannelCount = outCh
                        val prev = audioTrack
                        audioTrack = null
                        if (prev != null) {
                            try {
                                prev.pause()
                                prev.flush()
                                prev.stop()
                                prev.release()
                            } catch (_: Exception) {
                            }
                        }
                        audioTrack = createAndStartAudioTrack(outRate, outCh)
                    }
                } catch (_: Exception) {
                }
            } else if (outIdx >= 0) {
                try {
                    if (info.size > 0 && gen == pcmSessionGen.get()) {
                        val outBuf = codec.getOutputBuffer(outIdx)
                        if (outBuf != null) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            val pcm = ByteArray(info.size)
                            outBuf.get(pcm)
                            val track = audioTrack
                            if (track != null) {
                                var off = 0
                                val frameBytes = maxOf(2 * mp3ChannelCount, 2)
                                while (off < pcm.size && gen == pcmSessionGen.get()) {
                                    val written = try {
                                        track.write(pcm, off, pcm.size - off)
                                    } catch (_: Exception) {
                                        break
                                    }
                                    if (written <= 0) break
                                    off += written
                                    totalPcmFramesWritten.addAndGet((written / frameBytes).toLong())
                                }
                            }
                            if (!mp3FirstPcmLogged) {
                                mp3FirstPcmLogged = true
                                Log.i(
                                    "KidsTutorAudio",
                                    "MP3 first PCM decoded in ${System.currentTimeMillis() - mp3StreamStartMs}ms (${pcm.size} bytes)"
                                )
                            }
                        }
                    }
                } finally {
                    try {
                        codec.releaseOutputBuffer(outIdx, false)
                    } catch (_: Exception) {
                    }
                }
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    break
                }
            } else if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!waitForEos) break
            } else {
                @Suppress("DEPRECATION")
                if (outIdx != MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) {
                    break
                }
            }
        }
    }

    private fun awaitTrackDrainAndRelease(gen: Int) {
        val track = audioTrack
        if (track != null) {
            val startMs = System.currentTimeMillis()
            var lastHead = -1L
            var lastAdvanceMs = startMs
            while (gen == pcmSessionGen.get()) {
                val head = try {
                    track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                } catch (_: Exception) {
                    break
                }
                val target = totalPcmFramesWritten.get()
                if (head >= target) break
                val now = System.currentTimeMillis()
                if (head != lastHead) {
                    lastHead = head
                    lastAdvanceMs = now
                } else if (head > 0 && now - lastAdvanceMs > 500) {
                    break
                }
                if (now - startMs > 30000) break
                try {
                    Thread.sleep(25)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
        runOnUiThread {
            if (gen == pcmSessionGen.get()) {
                try {
                    audioTrack?.stop()
                    audioTrack?.release()
                } catch (_: Exception) {
                }
                audioTrack = null
            }
            val r = pendingPcmFinishResult
            pendingPcmFinishResult = null
            r?.success(true)
        }
    }

    private fun stopPlayer() {
        pcmSessionGen.incrementAndGet()
        totalPcmFramesWritten.set(0L)
        val finishRes = pendingPcmFinishResult
        pendingPcmFinishResult = null
        finishRes?.success(true)

        val playRes = pendingPlayWavResult
        pendingPlayWavResult = null
        playRes?.success(true)

        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null

        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {
        }
        audioTrack = null

        synchronized(codecLock) {
            try {
                mp3Codec?.stop()
            } catch (_: Exception) {
            }
            try {
                mp3Codec?.release()
            } catch (_: Exception) {
            }
            mp3Codec = null
        }
    }

    override fun onDestroy() {
        stopPlayer()
        pcmExecutor.shutdownNow()
        super.onDestroy()
    }
}
