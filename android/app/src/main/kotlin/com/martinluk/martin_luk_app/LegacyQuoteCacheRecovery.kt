package com.martinluk.martin_luk_app

import android.content.Context
import android.util.AtomicFile
import android.util.Log
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import org.xmlpull.v1.XmlPullParserFactory
import org.xmlpull.v1.XmlSerializer
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.FilterOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest

/** Only these disposable Yahoo response entries belong to this migration. */
internal object LegacyQuoteCacheXml {
    private val prefixes = listOf("flutter.market-data-yahoo-v1:", "market-data-yahoo-v1:")

    data class Summary(val removed: Int, val retained: Int)

    /**
     * Copy one entry at a time rather than building a Map of every preference.
     * Values of retained/unknown keys, including strings and sets, are copied
     * through the XML serializer. Skipped cache text is never requested from
     * the parser. The parser can still buffer an individual XML token, but this
     * code never holds the complete preferences file or a decoded quote map.
     */
    fun rewrite(
        input: InputStream,
        output: OutputStream,
        parser: XmlPullParser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = false }.newPullParser(),
        writer: XmlSerializer = XmlPullParserFactory.newInstance().newSerializer(),
    ): Summary {
        parser.setInput(input, null)
        writer.setOutput(output, "UTF-8")
        var rootSeen = false
        var rootClosed = false
        var removed = 0
        var retained = 0
        writer.startDocument("UTF-8", true)
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> {
                    if (parser.depth == 1) {
                        if (rootSeen || parser.name != "map") {
                            throw XmlPullParserException("Expected a single preferences map")
                        }
                        rootSeen = true
                    } else if (!rootSeen || rootClosed) {
                        throw XmlPullParserException("Entry outside preferences map")
                    }
                    val name = if (parser.depth == 2) parser.getAttributeValue(null, "name") else null
                    if (name != null && prefixes.any { name.startsWith(it) }) {
                        skipEntry(parser)
                        removed++
                        event = parser.nextToken()
                        continue
                    }
                    if (parser.depth == 2) retained++
                    writer.startTag(null, parser.name)
                    for (index in 0 until parser.attributeCount) {
                        writer.attribute(null, parser.getAttributeName(index), parser.getAttributeValue(index))
                    }
                }
                XmlPullParser.END_TAG -> {
                    writer.endTag(null, parser.name)
                    if (parser.depth == 1) rootClosed = true
                }
                XmlPullParser.TEXT, XmlPullParser.IGNORABLE_WHITESPACE -> writer.text(parser.text)
                XmlPullParser.CDSECT -> writer.cdsect(parser.text)
                XmlPullParser.ENTITY_REF -> {
                    val value = parser.text ?: throw XmlPullParserException("Unresolved XML entity")
                    writer.text(value)
                }
                XmlPullParser.COMMENT -> writer.comment(parser.text)
                XmlPullParser.PROCESSING_INSTRUCTION -> writer.processingInstruction(parser.text)
                XmlPullParser.DOCDECL -> throw XmlPullParserException("Document declarations are not preferences")
            }
            event = parser.nextToken()
        }
        if (!rootSeen || !rootClosed) throw XmlPullParserException("Incomplete preferences map")
        writer.endDocument()
        writer.flush()
        return Summary(removed, retained)
    }

    private fun skipEntry(parser: XmlPullParser) {
        val depth = parser.depth
        while (true) {
            when (parser.nextToken()) {
                XmlPullParser.END_DOCUMENT -> throw XmlPullParserException("Incomplete cache entry")
                XmlPullParser.DOCDECL -> throw XmlPullParserException("Document declarations are not preferences")
                XmlPullParser.END_TAG -> if (parser.depth == depth) return
            }
        }
    }
}

internal data class CacheRecoveryResult(val ready: Boolean, val message: String)

/** Run on the recovery IO thread before creating any FlutterEngine/plugin. */
internal object LegacyQuoteCacheRecovery {
    private const val TAG = "QuoteCacheRecovery"
    private const val MARKER_FILE = "legacy-yahoo-cache-recovered-v1.done"
    private val markerBytes = "legacy-yahoo-cache-recovered-v1\n".toByteArray(Charsets.UTF_8)

    fun recover(context: Context): CacheRecoveryResult {
        // A restored Android backup may contain the old giant preferences XML.
        // Never restore a completed marker alongside it and bypass recovery.
        val marker = AtomicFile(File(context.noBackupFilesDir, MARKER_FILE))
        val preferences = File(context.applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        val original = AtomicFile(preferences)
        var pendingOutput: FileOutputStream? = null
        try {
            if (hasMarker(marker)) return CacheRecoveryResult(true, "行情快取已就緒。")
            val backup = File(preferences.path + ".bak")
            val pending = File(preferences.path + ".new")
            if (!preferences.exists() && !backup.exists() && !pending.exists()) {
                writeMarker(marker)
                return CacheRecoveryResult(true, "尚無舊行情快取。")
            }

            // openRead first restores AtomicFile's previous backup if an old
            // process died mid-write. Do not use SharedPreferences/getAll here.
            val input = original.openRead()
            val beforeBytes = preferences.length()
            val digest = MessageDigest.getInstance("SHA-256")
            val (summary, output) = input.use {
                val raw = original.startWrite()
                pendingOutput = raw
                val output = CountingOutputStream(DigestOutputStream(raw, digest))
                val summary = LegacyQuoteCacheXml.rewrite(it, output)
                output.flush()
                summary to output
            }
            val expectedDigest = digest.digest()
            original.finishWrite(pendingOutput)
            pendingOutput = null
            // Some Android AtomicFile versions log a rename/sync error rather
            // than throwing it. Verify committed bytes before marking success.
            if (preferences.length() != output.count || !MessageDigest.isEqual(expectedDigest, sha256(preferences))) {
                throw IllegalStateException("Atomic preferences verification failed")
            }
            writeMarker(marker)
            Log.i(TAG, "completed removed=${summary.removed} retained=${summary.retained} bytesBefore=$beforeBytes bytesAfter=${output.count}")
            return CacheRecoveryResult(true, "舊行情快取已整理；持股與設定已保留。")
        } catch (error: Exception) {
            pendingOutput?.let {
                try {
                    original.failWrite(it)
                } catch (rollback: Exception) {
                    Log.w(TAG, "rollbackDeferred type=${rollback.javaClass.simpleName}")
                }
            }
            // Never log preference values, URLs, symbols or exception text.
            Log.w(TAG, "notCompleted type=${error.javaClass.simpleName}")
            return CacheRecoveryResult(false, "無法完成安全整理，持股與設定未清除。請確認手機有可用儲存空間後重試。")
        }
    }

    private fun hasMarker(marker: AtomicFile): Boolean {
        return try {
            marker.openRead().use { input ->
                val found = ByteArray(markerBytes.size + 1)
                var count = 0
                while (count < found.size) {
                    val size = input.read(found, count, found.size - count)
                    if (size < 0) break
                    count += size
                }
                count == markerBytes.size && found.copyOf(count).contentEquals(markerBytes)
            }
        } catch (_: java.io.FileNotFoundException) {
            false
        }
    }

    private fun writeMarker(marker: AtomicFile) {
        var output: FileOutputStream? = null
        try {
            output = marker.startWrite()
            output.write(markerBytes)
            marker.finishWrite(output)
            output = null
            if (!hasMarker(marker)) throw IllegalStateException("Atomic marker verification failed")
        } catch (error: Exception) {
            output?.let(marker::failWrite)
            throw error
        }
    }

    private fun sha256(file: File): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest()
    }

    private class CountingOutputStream(output: OutputStream) : FilterOutputStream(output) {
        var count = 0L
            private set

        override fun write(value: Int) {
            out.write(value)
            count++
        }

        override fun write(values: ByteArray, offset: Int, length: Int) {
            out.write(values, offset, length)
            count += length.toLong()
        }
    }
}
