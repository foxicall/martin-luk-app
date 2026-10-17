package com.martinluk.martin_luk_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.kxml2.io.KXmlParser
import org.kxml2.io.KXmlSerializer
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Real XML rewrite tests run in JVM CI; they never initialize Flutter/plugins. */
class LegacyQuoteCacheXmlTest {
    @Test
    fun removesOnlyExactTopLevelQuoteNamespacesAndPreservesEveryOtherEntry() {
        val source = """
            <?xml version="1.0" encoding="utf-8" standalone="yes"?>
            <map>
              <string name="flutter.market-data-yahoo-v1:NVDA:daily">{&quot;prices&quot;:[1,2,3]}</string>
              <string name="market-data-yahoo-v1:2330.TW:intraday">discard me</string>
              <string name="flutter.settings">{&quot;capitalUS&quot;:50000,&quot;capitalTW&quot;:1000000}</string>
              <string name="flutter.portfolio">台積電 &amp; NVDA &lt; retained &gt; "quotes"</string>
              <string name="flutter.martin-mobile-us-rolling-v1-progress">{&quot;cursor&quot;:300}</string>
              <string name="flutter.martin-mobile-tw-rolling-v1-recovery">{"pending":true}</string>
              <string name="unknown-market-data-yahoo-v1:keep">unknown key stays</string>
              <string name="flutter.market-data-yahoo-v10:keep">different version stays</string>
              <int name="count" value="7" />
              <long name="timestamp" value="1730000000000" />
              <float name="ratio" value="0.005" />
              <boolean name="enabled" value="true" />
              <set name="tags"><string>TW</string><string>US &amp; retained</string><string name="market-data-yahoo-v1:nested">nested value stays</string></set>
              <string name="whitespace">  first
            last  </string>
              <string name="empty"></string>
              <string name="cdata"><![CDATA[<not markup> & data]]></string>
            </map>
        """.trimIndent()
        val output = ByteArrayOutputStream()
        val summary = rewrite(source.byteInputStream(), output)
        val before = entries(source.byteInputStream())
        val after = entries(ByteArrayInputStream(output.toByteArray()))
        val expected = before.filterKeys { !it.startsWith("flutter.market-data-yahoo-v1:") && !it.startsWith("market-data-yahoo-v1:") }
        assertEquals(2, summary.removed)
        assertEquals(expected.size, summary.retained)
        assertEquals(expected, after)
        assertTrue(after.containsKey("flutter.portfolio"))
        assertTrue(after.getValue("tags").contains("nested value stays"))
        assertFalse(after.containsKey("flutter.market-data-yahoo-v1:NVDA:daily"))
    }

    @Test
    fun aLargeDisposableValueDoesNotBecomeAnOutputStringOrEntry() {
        val source = "<map><string name=\"flutter.market-data-yahoo-v1:large\">" +
            "x".repeat(2 * 1024 * 1024) +
            "</string><string name=\"portfolio\">retain me</string></map>"
        val output = ByteArrayOutputStream()
        val summary = rewrite(source.byteInputStream(), output)
        assertEquals(1, summary.removed)
        assertEquals(1, summary.retained)
        assertTrue(output.size() < 300)
        assertEquals("retain me", entries(ByteArrayInputStream(output.toByteArray())).getValue("portfolio").substringAfter("TEXT:").substringBefore("END:"))
    }

    @Test
    fun malformedInputFailsInsteadOfProducingACommittableSuccess() {
        val invalid = listOf(
            "<map><string name=\"flutter.market-data-yahoo-v1:bad\">unfinished",
            "<map><string name=\"portfolio\">missing end</map>",
            "<notmap><string name=\"portfolio\">wrong root</string></notmap>",
            "<map></map><map></map>",
            "<!DOCTYPE map [<!ENTITY bad SYSTEM 'file:///private'>]><map><string name=\"portfolio\">&bad;</string></map>",
        )
        for (source in invalid) {
            var failed = false
            try {
                rewrite(source.byteInputStream(), ByteArrayOutputStream())
            } catch (_: Exception) {
                failed = true
            }
            assertTrue("Malformed preferences must fail", failed)
        }
    }

    @Test
    fun aSecondRewriteIsIdempotentAndDoesNotDeleteUnknownOrNestedKeys() {
        val source = "<map><set name=\"keep\"><string name=\"flutter.market-data-yahoo-v1:nested\">yes</string></set><string name=\"future-cache-v9:keep\">value</string></map>"
        val first = ByteArrayOutputStream()
        val second = ByteArrayOutputStream()
        assertEquals(0, rewrite(source.byteInputStream(), first).removed)
        assertEquals(0, rewrite(ByteArrayInputStream(first.toByteArray()), second).removed)
        assertEquals(entries(source.byteInputStream()), entries(ByteArrayInputStream(second.toByteArray())))
    }

    private fun rewrite(input: InputStream, output: ByteArrayOutputStream): LegacyQuoteCacheXml.Summary =
        LegacyQuoteCacheXml.rewrite(input, output, KXmlParser(), KXmlSerializer())

    /** Token signatures compare types, attributes, nested sets and exact text. */
    private fun entries(input: InputStream): Map<String, String> {
        val parser = KXmlParser().apply { setInput(input, null) }
        val result = linkedMapOf<String, String>()
        var name: String? = null
        var value: StringBuilder? = null
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && parser.depth == 2) {
                name = parser.getAttributeValue(null, "name")
                value = StringBuilder()
            }
            val current = value
            if (current != null) {
                when (event) {
                    XmlPullParser.START_TAG -> {
                        current.append("START:").append(parser.name).append(';')
                        val attributes = (0 until parser.attributeCount).map {
                            parser.getAttributeName(it) to parser.getAttributeValue(it)
                        }.sortedBy { it.first }
                        current.append(attributes).append(';')
                    }
                    XmlPullParser.END_TAG -> current.append("END:").append(parser.name).append(';')
                    XmlPullParser.TEXT -> current.append("TEXT:").append(parser.text)
                }
            }
            if (event == XmlPullParser.END_TAG && parser.depth == 2) {
                result[requireNotNull(name)] = requireNotNull(value).toString()
                name = null
                value = null
            }
            // next merges ordinary text, entities and CDATA for value equality.
            event = parser.next()
        }
        return result
    }
}
