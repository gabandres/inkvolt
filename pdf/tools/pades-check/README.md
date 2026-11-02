# PAdES check

Roadmap 3.4's test says the EU DSS validator must report B-LTA for our signed files. This folder runs that validator on
this PC: [DSS](https://github.com/esig/dss) 6.5.1 (the European Commission's library, LGPL-2.1, the one behind its online
demo), called by `PadesCheck.java`, with no online CRL, OCSP or certificate source set, so it can only use what the file
holds and nothing goes anywhere. It isn't part of the app, and its libraries aren't committed or shipped.

```powershell
cd pdf/tools/pades-check
# once, with Maven (any 3.9; Java 17 or 21): the library and what it needs, into .cache/lib
mvn -q org.apache.maven.plugins:maven-dependency-plugin:3.8.1:copy-dependencies "-DoutputDirectory=.cache/lib" "-DincludeScope=runtime"
java -cp ".cache/lib/*" PadesCheck.java some.pdf trusted-root.cer   # one line per signature: format, indication, subindication
```

The tests run it on files they make, signed by a generated authority on this PC's loopback (`LtvTestPki`), with that
authority's root as the one trusted certificate:

```powershell
$env:INKVOLTPDF_PADES_CHECK = '1'                # PadesCheckTests.Eu_dss_reports_the_levels_we_claim
$env:INKVOLTPDF_PADES_KEEP = 'C:\somewhere'      # optional: keep the PDFs and the reports
dotnet test pdf/tests/InkvoltPdf.Tests --filter FullyQualifiedName~PadesCheckTests
```

It expects `PAdES-BASELINE-LT` and `-LTA` with `TOTAL_PASSED` for what signing and Add Verification Information make (OCSP
answers, CRLs only, a delegated responder, a no-changes certification, a file signed earlier without a timestamp), and
`-B` and `-T` for the plain ones. Those two come back INDETERMINATE, as they should: their chain's intermediate isn't in
the file, and the validator has nowhere else to look.

`INKVOLTPDF_LTV_APP` naming a built `InkvoltPdf.exe` also drives the real app against the same authority
(`The_real_app_adds_checks_and_signs`): its windows, shots and files go to `INKVOLTPDF_PADES_KEEP`.

Acrobat isn't on this PC, so "LTV enabled" in Acrobat hasn't been seen. To check it by hand: trust the root in Acrobat
(Preferences, Signatures, Identities & Trusted Certificates), open a kept `b-lta.pdf`, and look at the signature's
properties.
