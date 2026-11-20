import com.android.keyattestation.verifier.*
import com.android.keyattestation.verifier.challengecheckers.ChallengeMatcher
import com.google.gson.JsonParser
import com.google.protobuf.ByteString
import java.math.BigInteger
import java.security.Signature
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.time.Instant
import java.util.Base64
import java.util.HexFormat
import kotlin.system.exitProcess

// stdin is bounded by the identity service. Only the operator supplies the policy arguments.
fun main(args: Array<String>) {
    val proof = JsonParser.parseReader(System.`in`.reader()).asJsonObject
    val challenge = Base64.getUrlDecoder().decode(proof["challenge"].asString)
    val decoder = Base64.getDecoder()
    val factory = CertificateFactory.getInstance("X.509")
    val chain = try {
        proof["chain"].asJsonArray.map { factory.generateCertificate(decoder.decode(it.asString).inputStream()) as X509Certificate }
    } catch (_: CertificateException) {
        exitProcess(3)
    }
    // Accept an attested signing leaf. Reject chains that delegate attestation to another app key.
    if (chain.drop(1).any { it.getExtensionValue("1.3.6.1.4.1.11129.2.1.17") != null }) exitProcess(3)
    val app = AttestationApplicationId(
        setOf(AttestationPackageInfo(args[0], BigInteger(args[2]))),
        setOf(ByteString.copyFrom(HexFormat.of().parseHex(args[1]))),
    )
    val verifier = Verifier(
        GoogleTrustAnchors, ::getGoogleRevocationStatusFromWeb, Instant::now, app,
        ConstraintConfig(attestationApplicationId = AttestationApplicationIdConstraint.STRICT),
    )
    val result = verifier.verify(chain, ChallengeMatcher(ByteString.copyFrom(challenge)))
    if (result !is VerificationResult.Success || !result.deviceLocked ||
        result.verifiedBootState != VerifiedBootState.VERIFIED ||
        result.securityLevel !in setOf(SecurityLevel.TRUSTED_ENVIRONMENT, SecurityLevel.STRONG_BOX)) exitProcess(3)
    if (result.publicKey !is java.security.interfaces.ECPublicKey) exitProcess(3)
    val signature = Signature.getInstance("SHA256withECDSA")
    signature.initVerify(result.publicKey)
    signature.update("neon-android-ticket-v1\u0000".toByteArray(Charsets.US_ASCII))
    signature.update(challenge)
    val valid = try {
        signature.verify(decoder.decode(proof["signature"].asString))
    } catch (_: java.security.SignatureException) {
        false
    }
    if (!valid) exitProcess(3)
    println("verified")
}
