using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;

namespace InkvoltPrint.Core.Snmp;

/// <summary>SNMPv3 for <see cref="SnmpClient"/> (RFC 3412, RFC 3414, RFC 3826, RFC 7860): authPriv only, read only.</summary>
public sealed partial class SnmpClient
{
    private V3Engine? _engine;
    private long _salt = RandomNumberGenerator.GetInt32(int.MaxValue);

    /// <summary>The agent's engine as discovered: its ID, boots and time (and when that was), and the user's keys localized to it.</summary>
    private sealed class V3Engine(byte[] id, int boots, int time, Usm.Keys keys)
    {
        private long _at = Stopwatch.GetTimestamp();
        private int _time = time;

        public byte[] Id { get; } = id;
        public Usm.Keys Keys { get; } = keys;
        public int Boots { get; private set; } = boots;

        /// <summary>The engine's time now, as this manager reckons it (RFC 3414 §2.3).</summary>
        public int Time => (int)Math.Min(int.MaxValue, _time + (long)Stopwatch.GetElapsedTime(_at).TotalSeconds);

        /// <summary>An authenticated reply's boots and time: taken when later than reckoned (RFC 3414 §3.2 step 7b).</summary>
        public void Saw(int boots, int time)
        {
            if (boots < Boots || (boots == Boots && time <= Time)) return;
            Reset(boots, time);
        }

        /// <summary>The engine's own values (an authenticated notInTimeWindow report).</summary>
        public void Reset(int boots, int time) => (Boots, _time, _at) = (boots, time, Stopwatch.GetTimestamp());
    }

    /// <summary>
    /// One request over SNMPv3: the engine discovered first (once per client), the scoped PDU encrypted with AES-128 and the
    /// message signed with HMAC-SHA-256-192. An authenticated notInTimeWindow report sets the clock and sends again, an
    /// unknownEngineID report discovers again; any other report is the agent refusing the user or its keys.
    /// </summary>
    private async Task<SnmpMessage> SendV3Async(SnmpMessage pdu, CancellationToken ct)
    {
        var user = _user!;
        for (var round = 0; round < 3; round++)
        {
            var engine = _engine ??= await DiscoverAsync(user, ct).ConfigureAwait(false);
            var messageId = Interlocked.Increment(ref _requestId) & int.MaxValue;
            var salt = new byte[Usm.SaltLength];
            BinaryPrimitives.WriteInt64BigEndian(salt, Interlocked.Increment(ref _salt));
            var (boots, time) = (engine.Boots, engine.Time);
            var scoped = SnmpV3Message.EncodeScoped(engine.Id, "", pdu);
            var request = new SnmpV3Message
            {
                MessageId = messageId,
                Flags = SnmpV3Message.FlagAuth | SnmpV3Message.FlagPriv | SnmpV3Message.FlagReportable,
                EngineId = engine.Id, EngineBoots = boots, EngineTime = time, UserName = user.Name, PrivParameters = salt,
                Encrypted = Usm.AesCfb(engine.Keys.Priv, Usm.AesIv(boots, time, salt), scoped, encrypt: true),
            }.Sign(engine.Keys.Auth);
            var (reply, answer) = await ExchangeAsync(request, messageId, engine, ct).ConfigureAwait(false);
            if (answer.Type == SnmpPduType.Response)
            {
                if (answer.RequestId != pdu.RequestId) continue; // signed, but not this request's answer: ask again
                engine.Saw(reply.EngineBoots, reply.EngineTime);
                return answer;
            }
            var said = answer.VarBinds.Count > 0 ? answer.VarBinds[0].Name : null;
            if (Usm.NotInTimeWindows.Equals(said) && reply.Authenticated) engine.Reset(reply.EngineBoots, reply.EngineTime);
            else if (Usm.UnknownEngineIds.Equals(said)) _engine = null;
            else throw new SnmpAccessException(
                Usm.UnknownUserNames.Equals(said) ? SnmpRefusal.UnknownUser
                : Usm.WrongDigests.Equals(said) ? SnmpRefusal.WrongAuthKey
                : Usm.DecryptionErrors.Equals(said) ? SnmpRefusal.WrongPrivKey
                : SnmpRefusal.SecurityLevel);
        }
        throw new TimeoutException($"No SNMPv3 answer from {Host}: its engine's clock couldn't be agreed on.");
    }

    /// <summary>RFC 3414 §4: an empty request, neither signed nor encrypted; the agent reports its engine ID, boots and time.</summary>
    private async Task<V3Engine> DiscoverAsync(SnmpV3User user, CancellationToken ct)
    {
        var messageId = Interlocked.Increment(ref _requestId) & int.MaxValue;
        var request = new SnmpV3Message
        {
            MessageId = messageId, Flags = SnmpV3Message.FlagReportable, ContextEngineId = [],
            Pdu = new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.GetRequest, Interlocked.Increment(ref _requestId) & int.MaxValue, 0, 0, []),
        }.Encode();
        var (reply, _) = await ExchangeAsync(request, messageId, null, ct).ConfigureAwait(false);
        // RFC 3411's SnmpEngineID is 5 to 32 octets.
        if (reply.EngineId.Length is < 5 or > 32) throw new FormatException("SNMPv3: the agent reported no usable engine ID.");
        return new V3Engine(reply.EngineId, reply.EngineBoots, reply.EngineTime, Usm.Keys.For(user, reply.EngineId));
    }

    /// <summary>
    /// Sends a v3 request and waits for its reply (same msgID). A signed reply is read only with this engine's ID and the right
    /// digest, and decrypted with the user's key; an unsigned one only as a report (agents report errors unsigned). Anything
    /// else is no answer.
    /// </summary>
    private async Task<(SnmpV3Message Message, SnmpMessage Pdu)> ExchangeAsync(byte[] request, int messageId, V3Engine? engine, CancellationToken ct)
    {
        for (var attempt = 0; attempt <= Retries; attempt++)
        {
            if (await transport.SendAsync(Host, request, Timeout, ct).ConfigureAwait(false) is not { } bytes) continue;
            try
            {
                var reply = SnmpV3Message.Decode(bytes);
                if (reply.MessageId != messageId) continue;
                if (reply.Authenticated && (engine is null || !reply.EngineId.AsSpan().SequenceEqual(engine.Id) || !reply.Verify(bytes, engine.Keys.Auth)))
                    continue;
                if (reply.Private && !reply.Authenticated) continue; // privacy without authentication isn't a USM level
                SnmpMessage pdu;
                if (reply.Private)
                {
                    if (reply.Encrypted is null || reply.PrivParameters.Length != Usm.SaltLength) continue;
                    var iv = Usm.AesIv(reply.EngineBoots, reply.EngineTime, reply.PrivParameters);
                    pdu = SnmpV3Message.DecodeScoped(Usm.AesCfb(engine!.Keys.Priv, iv, reply.Encrypted, encrypt: false)).Pdu;
                }
                else pdu = reply.Pdu ?? throw new FormatException("SNMPv3: no PDU.");
                if (pdu.Type == SnmpPduType.Response && (!reply.Authenticated || !reply.Private || engine is null)) continue; // an answer must be signed and private
                if (pdu.Type is not (SnmpPduType.Response or SnmpPduType.Report)) continue;
                if (pdu.Type == SnmpPduType.Response && transport is ISnmpObserver observer) observer.Observe(pdu);
                return (reply, pdu);
            }
            catch (FormatException)
            {
                // not an SNMPv3 message for this request (garbage, another version, a damaged one): no answer
            }
        }
        throw new TimeoutException($"No SNMP reply from {Host}.");
    }
}

/// <summary>
/// A transport that wants each answer a client reads (a recording): SNMPv3 replies are encrypted on the wire, so the client
/// hands over the PDU once checked and decrypted.
/// </summary>
public interface ISnmpObserver
{
    void Observe(SnmpMessage reply);
}
