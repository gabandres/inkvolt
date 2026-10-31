using System.Text.Json;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Tests;

/// <summary>
/// The part of JSON Schema (draft 2020-12) that <c>print/schemas/fleet-status.schema.json</c> uses, so a test can hold the
/// command's output against the file in the repository without a package: type, const, enum, required, properties,
/// additionalProperties false, items, maxItems, minLength, maxLength, minimum, maximum, pattern and local $ref. A keyword it
/// doesn't know fails, so the schema can't quietly say more than is checked.
/// </summary>
internal static class JsonSchemaCheck
{
    private static readonly HashSet<string> Known =
    [
        "$schema", "$id", "$defs", "title", "description", "type", "const", "enum", "required", "properties", "additionalProperties",
        "items", "maxItems", "minLength", "maxLength", "minimum", "maximum", "pattern", "$ref",
    ];

    /// <summary>Every place <paramref name="document"/> breaks <paramref name="schema"/>; empty when it validates.</summary>
    public static IReadOnlyList<string> Errors(JsonElement schema, JsonElement document)
    {
        var errors = new List<string>();
        Check(schema, schema, document, "$", errors);
        return errors;
    }

    private static void Check(JsonElement root, JsonElement schema, JsonElement value, string at, List<string> errors)
    {
        foreach (var keyword in schema.EnumerateObject())
            if (!Known.Contains(keyword.Name)) throw new NotSupportedException($"The schema uses {keyword.Name}, which this check doesn't know.");

        if (schema.TryGetProperty("$ref", out var reference))
        {
            var target = root;
            foreach (var part in reference.GetString()!.TrimStart('#', '/').Split('/')) target = target.GetProperty(part);
            Check(root, target, value, at, errors);
            return;
        }
        if (schema.TryGetProperty("type", out var type) && !TypeMatches(type, value)) errors.Add($"{at}: is {value.ValueKind}, the schema says {type}");
        if (schema.TryGetProperty("const", out var constant) && value.GetRawText() != constant.GetRawText()) errors.Add($"{at}: is not {constant}");
        if (schema.TryGetProperty("enum", out var choices) && !choices.EnumerateArray().Any(c => c.GetRawText() == value.GetRawText()))
            errors.Add($"{at}: {value} isn't one of {choices}");

        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString()!;
            if (schema.TryGetProperty("minLength", out var min) && text.Length < min.GetInt32()) errors.Add($"{at}: shorter than {min}");
            if (schema.TryGetProperty("maxLength", out var max) && text.Length > max.GetInt32()) errors.Add($"{at}: longer than {max}");
            if (schema.TryGetProperty("pattern", out var pattern) && !Regex.IsMatch(text, pattern.GetString()!)) errors.Add($"{at}: \"{text}\" doesn't match {pattern}");
        }
        if (value.ValueKind == JsonValueKind.Number)
        {
            if (schema.TryGetProperty("minimum", out var min) && value.GetDouble() < min.GetDouble()) errors.Add($"{at}: under {min}");
            if (schema.TryGetProperty("maximum", out var max) && value.GetDouble() > max.GetDouble()) errors.Add($"{at}: over {max}");
        }
        if (value.ValueKind == JsonValueKind.Array)
        {
            if (schema.TryGetProperty("maxItems", out var most) && value.GetArrayLength() > most.GetInt32()) errors.Add($"{at}: more than {most} items");
            if (schema.TryGetProperty("items", out var items))
            {
                var i = 0;
                foreach (var item in value.EnumerateArray()) Check(root, items, item, $"{at}[{i++}]", errors);
            }
        }
        if (value.ValueKind == JsonValueKind.Object)
        {
            if (schema.TryGetProperty("required", out var required))
                foreach (var name in required.EnumerateArray())
                    if (!value.TryGetProperty(name.GetString()!, out _)) errors.Add($"{at}: {name} is missing");
            schema.TryGetProperty("properties", out var properties);
            var closed = schema.TryGetProperty("additionalProperties", out var additional) && additional.ValueKind == JsonValueKind.False;
            foreach (var property in value.EnumerateObject())
            {
                if (properties.ValueKind == JsonValueKind.Object && properties.TryGetProperty(property.Name, out var sub))
                    Check(root, sub, property.Value, $"{at}.{property.Name}", errors);
                else if (closed) errors.Add($"{at}: {property.Name} isn't in the schema");
            }
        }
    }

    private static bool TypeMatches(JsonElement type, JsonElement value)
    {
        if (type.ValueKind == JsonValueKind.Array) return type.EnumerateArray().Any(t => TypeMatches(t, value));
        return type.GetString() switch
        {
            "object" => value.ValueKind == JsonValueKind.Object,
            "array" => value.ValueKind == JsonValueKind.Array,
            "string" => value.ValueKind == JsonValueKind.String,
            "boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
            "null" => value.ValueKind == JsonValueKind.Null,
            "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _),
            "number" => value.ValueKind == JsonValueKind.Number,
            var other => throw new NotSupportedException($"Unknown type {other}"),
        };
    }
}
