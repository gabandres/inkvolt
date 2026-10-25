using System.Globalization;

namespace InkvoltPrint.Core.Snmp;

/// <summary>An SNMP object identifier (<c>1.3.6.1.2.1.1.1.0</c>): its arcs, ordered as SNMP walks them (lexicographically).</summary>
public sealed class Oid : IEquatable<Oid>, IComparable<Oid>
{
    private readonly uint[] _arcs;

    public Oid(params uint[] arcs)
    {
        // X.690 §8.19.4: the first two arcs share one subidentifier (40 * first + second), so the first is 0, 1 or 2.
        if (arcs.Length < 2 || arcs[0] > 2 || (arcs[0] < 2 && arcs[1] >= 40)) throw new ArgumentException("Not an object identifier.", nameof(arcs));
        if (arcs.Length > 128) throw new ArgumentException("SNMP allows at most 128 arcs.", nameof(arcs)); // RFC 2578 §3.5
        _arcs = (uint[])arcs.Clone();
    }

    public IReadOnlyList<uint> Arcs => _arcs;

    public int Length => _arcs.Length;

    /// <summary>"1.3.6.1.2.1.1.1.0" or ".1.3.6.1.2.1.1.1.0" (net-snmp's numeric form).</summary>
    public static Oid Parse(string text) =>
        new(text.Trim().TrimStart('.').Split('.').Select(a => uint.Parse(a, NumberStyles.None, CultureInfo.InvariantCulture)).ToArray());

    public Oid Append(params uint[] more) => new([.. _arcs, .. more]);

    /// <summary>Strictly under <paramref name="prefix"/> (longer, and starting with all of its arcs).</summary>
    public bool IsUnder(Oid prefix) => _arcs.Length > prefix._arcs.Length && _arcs.AsSpan(0, prefix._arcs.Length).SequenceEqual(prefix._arcs);

    /// <summary>The arcs after <paramref name="prefix"/> (a table row's index), or null when this isn't under it.</summary>
    public uint[]? After(Oid prefix) => IsUnder(prefix) ? _arcs[prefix._arcs.Length..] : null;

    public int CompareTo(Oid? other)
    {
        if (other is null) return 1;
        var n = Math.Min(_arcs.Length, other._arcs.Length);
        for (var i = 0; i < n; i++)
            if (_arcs[i] != other._arcs[i]) return _arcs[i] < other._arcs[i] ? -1 : 1;
        return _arcs.Length.CompareTo(other._arcs.Length);
    }

    public bool Equals(Oid? other) => other is not null && _arcs.AsSpan().SequenceEqual(other._arcs);

    public override bool Equals(object? obj) => obj is Oid o && Equals(o);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var a in _arcs) h.Add(a);
        return h.ToHashCode();
    }

    public override string ToString() => string.Join('.', _arcs);
}
