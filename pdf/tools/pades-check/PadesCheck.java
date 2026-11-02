import eu.europa.esig.dss.model.FileDocument;
import eu.europa.esig.dss.simplereport.SimpleReport;
import eu.europa.esig.dss.spi.DSSUtils;
import eu.europa.esig.dss.spi.validation.CommonCertificateVerifier;
import eu.europa.esig.dss.spi.x509.CommonTrustedCertificateSource;
import eu.europa.esig.dss.validation.SignedDocumentValidator;
import eu.europa.esig.dss.validation.reports.Reports;

import java.io.File;

/**
 * Validates a PDF with the EU's DSS library on this PC, offline: no online CRL, OCSP or certificate source is set, so it
 * can only use what the file holds, and nothing is sent anywhere. Prints one line per signature: its format, then
 * indication, subindication, and the validator's errors and warnings.
 *
 *   java -cp ".cache/lib/*" PadesCheck.java file.pdf [trusted-root.cer ...]
 */
public class PadesCheck {
    public static void main(String[] args) throws Exception {
        var trusted = new CommonTrustedCertificateSource();
        for (var i = 1; i < args.length; i++) trusted.addCertificate(DSSUtils.loadCertificate(new File(args[i])));
        var verifier = new CommonCertificateVerifier();
        verifier.setTrustedCertSources(trusted);
        verifier.setAIASource(null);
        verifier.setCrlSource(null);
        verifier.setOcspSource(null);
        var validator = SignedDocumentValidator.fromDocument(new FileDocument(args[0]));
        validator.setCertificateVerifier(verifier);
        Reports reports = validator.validateDocument();
        SimpleReport report = reports.getSimpleReport();
        for (var id : report.getSignatureIdList()) {
            System.out.println("SIGNATURE " + report.getSignatureFormat(id) + " " + report.getIndication(id) + " " + report.getSubIndication(id));
            for (var m : report.getAdESValidationErrors(id)) System.out.println("  error: " + m.getValue());
            for (var m : report.getAdESValidationWarnings(id)) System.out.println("  warning: " + m.getValue());
            for (var t : report.getSignatureTimestamps(id))
                System.out.println("  timestamp " + t.getProductionTime().toInstant() + " " + t.getIndication() + " " + t.getSubIndication());
        }
        for (var id : report.getTimestampIdList()) {
            System.out.println("TIMESTAMP " + report.getIndication(id) + " " + report.getSubIndication(id));
            for (var m : report.getAdESValidationErrors(id)) System.out.println("  error: " + m.getValue());
            for (var m : report.getAdESValidationWarnings(id)) System.out.println("  warning: " + m.getValue());
        }
        if (report.getSignatureIdList().isEmpty() && report.getTimestampIdList().isEmpty()) System.out.println("NO SIGNATURES");
    }
}
