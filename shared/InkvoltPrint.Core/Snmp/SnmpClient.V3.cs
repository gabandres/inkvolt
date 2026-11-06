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
        private int _latest = time; // RFC 3414 §2.3's latestReceivedEngineTime

        public byte[] Id { get; } = id;
        public Usm.Keys Keys { get; } = keys;
        public int Boots { get; private set; } = boots;

        /// <summary>The engine's time now, as this manager reckons it (RFC 3414 §2.3).</summary>
        public int Time => (int)Math.Min(int.MaxValue, _time + (long)Stopwatch.GetElapsedTime(_at).TotalSeconds);

        /// <summary>
        /// RFC 3414 §3.2 step 7b: an authenticated message is outside the engine's time window when the engine's boots reached
        /// their end, its boots are behind, or with the same boots its time is more than 150 s behind the time reckoned (an old
        /// message sent again). Such a message is no answer, and moves nothing.
        /// </summary>
        public bool InWindow(int boots, int time) =>
            Boots < int.MaxValue && boots >= Boots && (boots > Boots || time >= (long)Time - Usm.TimeWindow);

        /// <summary>An authenticated message's boots and time, once in the window: taken when later than the latest received (RFC 3414 §3.2 step 7b).</summary>
        public void Saw(int boots, int time)
        {
            if (boots > Boots || (boots == Boots && time > _latest)) Reset(boots, time);
        }

        /// <summary>The engine's own values (an authenticated notInTimeWindow report).</summary>
        public void Reset(int boots, int time) => (Boots, _time, _latest, _at) = (boots, time, time, Stopwatch.GetTimestamp());
    }

    /// <summary>
    /// One request over SNMPv3: the engine discovered first (once per client), the scoped PDU encrypted with AES-128 and the
    /// message signed with HMAC-SHA-256-192. A signed notInTimeWindow report sets the clock and sends again (once); a refusal
    /// from the engine is an <see cref="SnmpAccessException"/> saying which part; reports RFC 3414 doesn't let a manager act
    /// on are no answer (<see cref="ActedOn"/>).
    /// </summary>
    private async Task<SnmpMessage> SendV3Async(SnmpMessage pdu, CancellationToken ct)
    {
        var user = _user!;
        var resynchronized = false;
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
                engine.Saw(reply.EngineBoots, reply.EngineTime); // in its window (ExchangeAsync)
                return answer;
            }
            var said = Counter(answer);
            if (!Usm.NotInTimeWindows.Equals(said)) throw new SnmpAccessException(Refusals.First(r => r.Counter.Equals(said)).Reason);
            // Signed (ExchangeAsync lets no other through): the engine's own clock, taken once a request; again, it's no answer.
            if (resynchronized) break;
            resynchronized = true;
            engine.Reset(reply.EngineBoots, reply.EngineTime);
        }
        throw new TimeoutException($"No SNMPv3 answer from {Host}: its engine's clock couldn't be agreed on.");
    }

    /// <summary>The usmStats counters an agent reports for a request it refuses (RFC 3414 §3.2), and what each says is wrong.</summary>
    private static readonly (Oid Counter, SnmpRefusal Reason)[] Refusals =
    [
        (Usm.UnknownUserNames, SnmpRefusal.UnknownUser), (Usm.WrongDigests, SnmpRefusal.WrongAuthKey),
        (Usm.DecryptionErrors, SnmpRefusal.WrongPrivKey), (Usm.UnsupportedSecLevels, SnmpRefusal.SecurityLevel),
    ];

    private static Oid? Counter(SnmpMessage pdu) => pdu.VarBinds.Count > 0 ? pdu.VarBinds[0].Name : null;

    /// <summary>
    /// A report this manager acts on (RFC 3414 §3.2, §4): before the engine is known, only discovery's unknownEngineID
    /// (unsigned: there are no keys yet); after, a notInTimeWindow only signed (the clock is set from it), or a refusal from
    /// the engine discovered, signed or not (an agent can't sign for a user or key it refuses). Any other report could come
    /// from anyone on the network: no answer.
    /// </summary>
    private static bool ActedOn(SnmpV3Message reply, Oid? counter, V3Engine? engine)
    {
        if (engine is null) return Usm.UnknownEngineIds.Equals(counter) && !reply.Authenticated;
        if (Usm.NotInTimeWindows.Equals(counter)) return reply.Authenticated;
        return reply.EngineId.AsSpan().SequenceEqual(engine.Id) && Refusals.Any(r => r.Counter.Equals(counter));
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
    /// Sends a v3 request and waits for its reply (same msgID). A signed reply is read only with this engine's ID, the right
    /// digest and in the engine's time window, and decrypted with the user's key; an unsigned one only as a report RFC 3414 lets
    /// a manager act on (agents report errors unsigned). Anything else is no answer.
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
                var counter = Counter(pdu);
                if (pdu.Type == SnmpPduType.Report && !ActedOn(reply, counter, engine)) continue; // a report RFC 3414 lets a manager act on
                // Signed but outside the engine's time window (an old message sent again): no answer. A notInTimeWindow report
                // is the engine telling its own clock.
                var resync = pdu.Type == SnmpPduType.Report && Usm.NotInTimeWindows.Equals(counter);
                if (reply.Authenticated && !resync && engine is not null && !engine.InWindow(reply.EngineBoots, reply.EngineTime)) continue;
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
