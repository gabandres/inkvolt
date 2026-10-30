# pro-key: the Inkvolt Pro licence tool

Makes the signing key pair, issues a licence key for a purchase and checks one. Not shipped. The format it writes is
what `ProKeys` in `pdf/src/InkvoltPdf.Core/Pro.cs` reads (and the Mac port will read with CryptoKit); `test-vector.json`
here is the shared check.

```powershell
dotnet run --project pdf/tools/pro-key -- keygen                                   # once: the pair into %USERPROFILE%\.inkvolt-pro
dotnet run --project pdf/tools/pro-key -- issue --name "Full Name" --email who@example.com [--date 2026-10-30] [--products pdf,print]
dotnet run --project pdf/tools/pro-key -- check INKVOLT-PRO-…                      # what a key says, or why it is refused
```

`keygen` writes `inkvolt-pro.key` (the **private** key, PKCS#8 PEM) and `inkvolt-pro.pub` (the public key) to
`%USERPROFILE%\.inkvolt-pro` (`--dir` for another folder) and refuses to overwrite. The private key is never in the repo
and never printed; its backup is the `Inkvolt Pro licence key` folder under the company's Keys folder on OneDrive, with a
README on restoring and rotating. The public key goes into Core as `ProKeys.PublicKeyBase64` (`keygen` prints it);
`issue` warns when the private key it holds doesn't match the one built in.

## The key format (version 1)

A key is text a person pastes into Help › Inkvolt Pro…:

```
INKVOLT-PRO-AFAWI-YJAJR-XXMZL-MMFRW-…-GYQ
```

- The prefix `INKVOLT-PRO-`, then **base32** (RFC 4648 alphabet `A-Z2-7`, uppercase, no padding) in groups of five
  joined by hyphens. A reader ignores whitespace, hyphens and case before decoding, so a key wrapped in an email still
  reads.
- The base32 decodes to `payload || signature`; the signature is the last 64 bytes, the payload everything before it.
- **Payload**: one version byte (`0x01`), then UTF-8 text of four lines joined by `\n` (no trailing newline):
  1. the licensee's name
  2. their email
  3. the issue date, `yyyy-MM-dd`
  4. the products, comma-separated: `pdf`, `print` (Inkvolt Print reserved; one key may list both)
- **Signature**: ECDSA on the NIST P-256 curve over SHA-256 of the whole payload (version byte included), encoded as
  `r || s`, 32 bytes each (IEEE P1363 fixed-field; what .NET's `DSASignatureFormat.IeeeP1363FixedFieldConcatenation`
  writes and CryptoKit's `P256.Signing.ECDSASignature(rawRepresentation:)` reads).
- **Public key**: the uncompressed point, 65 bytes (`0x04 || X || Y`), base64 in the apps (`ProKeys.PublicKeyBase64`;
  CryptoKit: `P256.Signing.PublicKey(x963Representation:)`).

Reading is strict, each refusal with a plain reason: empty; not starting with the prefix; a character outside the
alphabet; too short to hold a payload and a signature; a version byte other than 1 ("made for a newer version");
signature doesn't verify ("altered or didn't paste whole"); payload not four lines or the date not a date. Inkvolt PDF
then also refuses a verified key that doesn't list `pdf`. With the signature over the version byte and all four lines,
nothing in a key can be changed without a new signature.

Why P-256 and not Ed25519: .NET 10 has no Ed25519 without a package (the apps take no new dependency for this), and
CryptoKit has both; P-256 is the one both sides have.

## Test vector

`test-vector.json`: the public key, a valid key (Ada Lovelace, `pdf,print`, 2026-10-30) with what it must read as, the
same key with one character changed (must be refused as altered), and a valid key for `print` only (reads, but Inkvolt
PDF refuses to install it). `ProTests` in `pdf/tests/InkvoltPdf.Tests` checks all three against the public key built
into Core; the Mac port's tests use the same file.
