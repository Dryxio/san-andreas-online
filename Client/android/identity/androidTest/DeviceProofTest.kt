package org.mtamobile.identity.test

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import org.mtamobile.identity.AndroidTicketProof
import java.io.File

class DeviceProofTest : Instrumentation() {
    private lateinit var nonce: String
    override fun onCreate(arguments: Bundle) {
        super.onCreate(arguments)
        nonce = arguments.getString("challenge")!!
        start()
    }
    override fun onStart() {
        val result = Bundle()
        try {
            File(targetContext.cacheDir, "neon-proof-test.json").writeText(AndroidTicketProof.create(nonce).toString())
            finish(Activity.RESULT_OK, result)
        } catch (error: Exception) {
            result.putString("failure", error.javaClass.simpleName)
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
