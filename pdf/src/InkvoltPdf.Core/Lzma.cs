namespace InkvoltPdf.Core;

/// <summary>
/// An LZMA (LZMA1) decoder, after the format's public-domain reference decoder (Igor Pavlov's LzmaSpec): what takes
/// tesseract.exe and its DLLs out of the Tesseract installer's solid stream (<see cref="TesseractStore"/>) without
/// running the installer. Streaming: the dictionary is the only buffer, the output goes to a <see cref="Stream"/>. Input
/// is untrusted however it was checked: a corrupt stream throws <see cref="InvalidDataException"/>, never loops, and the
/// output is bounded.
/// </summary>
public static class Lzma
{
    private const int MaxDictionary = 1 << 28; // 256 MB: more than any installer this reads uses (NSIS: 32 MB at most)

    /// <summary>
    /// Decodes the stream that starts at <paramref name="input"/>'s position: its properties byte, its dictionary size
    /// (4 bytes, little-endian), then the range-coded data, which ends with the end marker (NSIS writes one), at
    /// <paramref name="stopAfter"/> bytes of output when given, or at the end of the input.
    /// </summary>
    /// <param name="maxOutput">More output than this is a corrupt stream.</param>
    /// <returns>The bytes written.</returns>
    public static long Decode(Stream input, Stream output, long maxOutput, long? stopAfter = null, IProgress<long>? progress = null,
        CancellationToken cancel = default)
    {
        Span<byte> header = stackalloc byte[5];
        input.ReadExactly(header);
        int props = header[0];
        if (props >= 9 * 5 * 5) throw new InvalidDataException("Not an LZMA stream.");
        var dictSize = BitConverter.ToUInt32(header[1..]);
        if (dictSize > MaxDictionary) throw new InvalidDataException("The LZMA dictionary is too large.");
        var decoder = new Decoder(input, output, props % 9, props / 9 % 5, props / 45, (int)Math.Max(dictSize, 1u << 12), maxOutput,
            stopAfter, progress, cancel);
        return decoder.Run();
    }

    private sealed class Decoder
    {
        private const int NumStates = 12;
        private const int PosBitsMax = 4;
        private const int LenToPosStates = 4;
        private const int EndPosModelIndex = 14;
        private const int FullDistances = 1 << (EndPosModelIndex >> 1);
        private const int AlignBits = 4;
        private const int MatchMinLen = 2;
        private const ushort ProbInit = 1 << 10;

        private readonly Stream _output;
        private readonly int _lc, _lp, _pb;
        private readonly long _maxOutput;
        private readonly long? _stopAfter;
        private readonly IProgress<long>? _progress;
        private readonly CancellationToken _cancel;
        private readonly Range _range;

        // The dictionary (a ring), what of it was written out, and the bytes so far.
        private readonly byte[] _dict;
        private int _pos;
        private int _flushed;
        private bool _full;
        private long _total;
        private long _nextReport;
        private long _steps;

        private readonly ushort[] _literals;
        private readonly ushort[] _posSlot = new ushort[LenToPosStates << 6];
        private readonly ushort[] _posDecoders = new ushort[1 + FullDistances - EndPosModelIndex];
        private readonly ushort[] _align = new ushort[1 << AlignBits];
        private readonly ushort[] _isMatch = new ushort[NumStates << PosBitsMax];
        private readonly ushort[] _isRep = new ushort[NumStates];
        private readonly ushort[] _isRepG0 = new ushort[NumStates];
        private readonly ushort[] _isRepG1 = new ushort[NumStates];
        private readonly ushort[] _isRepG2 = new ushort[NumStates];
        private readonly ushort[] _isRep0Long = new ushort[NumStates << PosBitsMax];
        private readonly Lengths _len = new();
        private readonly Lengths _repLen = new();

        public Decoder(Stream input, Stream output, int lc, int lp, int pb, int dictSize, long maxOutput, long? stopAfter,
            IProgress<long>? progress, CancellationToken cancel)
        {
            (_output, _lc, _lp, _pb, _maxOutput, _stopAfter, _progress, _cancel) = (output, lc, lp, pb, maxOutput, stopAfter, progress, cancel);
            _dict = new byte[dictSize];
            _literals = new ushort[0x300 << (lc + lp)];
            foreach (var probs in new[] { _literals, _posSlot, _posDecoders, _align, _isMatch, _isRep, _isRepG0, _isRepG1, _isRepG2, _isRep0Long })
                Array.Fill(probs, ProbInit);
            _range = new Range(input);
        }

        public long Run()
        {
            uint rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0;
            var state = 0;
            var pbMask = (1 << _pb) - 1;
            while (true)
            {
                if (_stopAfter is { } stop && _total >= stop) break;
                if ((++_steps & 0xFFFF) == 0)
                {
                    _cancel.ThrowIfCancellationRequested();
                    if (_total >= _nextReport)
                    {
                        _progress?.Report(_total);
                        _nextReport = _total + (1 << 20);
                    }
                }
                var posState = (int)(_total & pbMask);
                if (_range.Bit(ref _isMatch[(state << PosBitsMax) + posState]) == 0)
                {
                    Literal(state, rep0);
                    state = state < 4 ? 0 : state < 10 ? state - 3 : state - 6;
                    continue;
                }
                int len;
                if (_range.Bit(ref _isRep[state]) != 0)
                {
                    if (_total == 0) throw Corrupt();
                    if (_range.Bit(ref _isRepG0[state]) == 0)
                    {
                        if (_range.Bit(ref _isRep0Long[(state << PosBitsMax) + posState]) == 0)
                        {
                            state = state < 7 ? 9 : 11;
                            Put(Get(rep0 + 1));
                            continue;
                        }
                    }
                    else
                    {
                        uint dist;
                        if (_range.Bit(ref _isRepG1[state]) == 0) dist = rep1;
                        else
                        {
                            if (_range.Bit(ref _isRepG2[state]) == 0) dist = rep2;
                            else
                            {
                                dist = rep3;
                                rep3 = rep2;
                            }
                            rep2 = rep1;
                        }
                        rep1 = rep0;
                        rep0 = dist;
                    }
                    len = _repLen.Decode(_range, posState);
                    state = state < 7 ? 8 : 11;
                }
                else
                {
                    rep3 = rep2;
                    rep2 = rep1;
                    rep1 = rep0;
                    len = _len.Decode(_range, posState);
                    state = state < 7 ? 7 : 10;
                    rep0 = Distance(len);
                    if (rep0 == 0xFFFFFFFF)
                    {
                        if (!_range.FinishedOk) throw Corrupt();
                        break; // the end marker
                    }
                    if (rep0 >= _dict.Length || !(rep0 < _pos || _full)) throw Corrupt();
                }
                len += MatchMinLen;
                for (var i = 0; i < len; i++) Put(Get(rep0 + 1));
            }
            Flush();
            _progress?.Report(_total);
            return _total;
        }

        private void Literal(int state, uint rep0)
        {
            var prevByte = _total == 0 ? 0 : Get(1);
            var litState = (int)(((_total & ((1 << _lp) - 1)) << _lc) + (prevByte >> (8 - _lc)));
            var probs = _literals.AsSpan(0x300 * litState, 0x300);
            var symbol = 1;
            if (state >= 7)
            {
                if (_total == 0) throw Corrupt();
                int matchByte = Get(rep0 + 1);
                do
                {
                    var matchBit = (matchByte >> 7) & 1;
                    matchByte <<= 1;
                    var bit = _range.Bit(ref probs[((1 + matchBit) << 8) + symbol]);
                    symbol = (symbol << 1) | bit;
                    if (matchBit != bit) break;
                }
                while (symbol < 0x100);
            }
            while (symbol < 0x100) symbol = (symbol << 1) | _range.Bit(ref probs[symbol]);
            Put((byte)(symbol - 0x100));
        }

        private uint Distance(int len)
        {
            var lenState = Math.Min(len, LenToPosStates - 1);
            var posSlot = (int)_range.Tree(_posSlot.AsSpan(lenState << 6, 1 << 6), 6);
            if (posSlot < 4) return (uint)posSlot;
            var directBits = (posSlot >> 1) - 1;
            var dist = (uint)((2 | (posSlot & 1)) << directBits);
            if (posSlot < EndPosModelIndex) return dist + _range.ReverseTree(_posDecoders.AsSpan((int)dist - posSlot), directBits);
            dist += _range.Direct(directBits - AlignBits) << AlignBits;
            return dist + _range.ReverseTree(_align, AlignBits);
        }

        private byte Get(uint dist)
        {
            if (dist > _dict.Length || (!_full && dist > _pos)) throw Corrupt();
            var at = _pos - (int)dist;
            return _dict[at < 0 ? at + _dict.Length : at];
        }

        private void Put(byte b)
        {
            if (++_total > _maxOutput) throw new InvalidDataException("The LZMA stream is longer than it may be.");
            _dict[_pos++] = b;
            if (_pos == _dict.Length)
            {
                Flush();
                _pos = 0;
                _flushed = 0;
                _full = true;
            }
        }

        private void Flush()
        {
            if (_pos > _flushed) _output.Write(_dict, _flushed, _pos - _flushed);
            _flushed = _pos;
        }

        private static InvalidDataException Corrupt() => new("The LZMA stream is corrupt.");

        /// <summary>A length (2-273, less <see cref="MatchMinLen"/>): low (8, per position), mid (8, per position) or high (256).</summary>
        private sealed class Lengths
        {
            private ushort _choice = ProbInit, _choice2 = ProbInit;
            private readonly ushort[] _low = Fill(new ushort[16 << 3]);
            private readonly ushort[] _mid = Fill(new ushort[16 << 3]);
            private readonly ushort[] _high = Fill(new ushort[1 << 8]);

            private static ushort[] Fill(ushort[] a)
            {
                Array.Fill(a, ProbInit);
                return a;
            }

            public int Decode(Range range, int posState)
            {
                if (range.Bit(ref _choice) == 0) return (int)range.Tree(_low.AsSpan(posState << 3, 8), 3);
                if (range.Bit(ref _choice2) == 0) return 8 + (int)range.Tree(_mid.AsSpan(posState << 3, 8), 3);
                return 16 + (int)range.Tree(_high, 8);
            }
        }
    }

    /// <summary>The range decoder: bits with adaptive probabilities, and direct bits.</summary>
    private sealed class Range
    {
        private const uint Top = 1u << 24;
        private readonly Stream _input;
        private readonly byte[] _buffer = new byte[1 << 16];
        private int _at, _length;
        private uint _range = 0xFFFFFFFF, _code;

        public Range(Stream input)
        {
            _input = input;
            if (Next() != 0) throw new InvalidDataException("The LZMA stream is corrupt.");
            for (var i = 0; i < 4; i++) _code = (_code << 8) | Next();
            if (_code == _range) throw new InvalidDataException("The LZMA stream is corrupt.");
        }

        public bool FinishedOk => _code == 0;

        private byte Next()
        {
            if (_at == _length)
            {
                _length = _input.Read(_buffer, 0, _buffer.Length);
                _at = 0;
                if (_length <= 0) throw new InvalidDataException("The LZMA stream ends too soon.");
            }
            return _buffer[_at++];
        }

        private void Normalize()
        {
            if (_range < Top)
            {
                _range <<= 8;
                _code = (_code << 8) | Next();
            }
        }

        public int Bit(ref ushort prob)
        {
            var bound = (_range >> 11) * prob;
            int bit;
            if (_code < bound)
            {
                prob += (ushort)(((1 << 11) - prob) >> 5);
                _range = bound;
                bit = 0;
            }
            else
            {
                prob -= (ushort)(prob >> 5);
                _code -= bound;
                _range -= bound;
                bit = 1;
            }
            Normalize();
            return bit;
        }

        public uint Direct(int bits)
        {
            uint result = 0;
            for (; bits > 0; bits--)
            {
                _range >>= 1;
                _code -= _range;
                var t = 0u - (_code >> 31);
                _code += _range & t;
                if (_code == _range) throw new InvalidDataException("The LZMA stream is corrupt.");
                Normalize();
                result = (result << 1) + t + 1;
            }
            return result;
        }

        public uint Tree(Span<ushort> probs, int bits)
        {
            var m = 1;
            for (var i = 0; i < bits; i++) m = (m << 1) + Bit(ref probs[m]);
            return (uint)(m - (1 << bits));
        }

        public uint ReverseTree(Span<ushort> probs, int bits)
        {
            var m = 1;
            uint symbol = 0;
            for (var i = 0; i < bits; i++)
            {
                var bit = Bit(ref probs[m]);
                m = (m << 1) + bit;
                symbol |= (uint)bit << i;
            }
            return symbol;
        }
    }
}
