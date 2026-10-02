package notes;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Just enough JSON for this API, so it needs no JSON library. */
final class Json {
    private static final Pattern TEXT = Pattern.compile("^\\s*\\{\\s*\"text\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*}\\s*$");

    static String quote(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"";
    }

    /** The "text" field of {"text": "..."}, or null when the body isn't that shape. */
    static String text(String body) {
        Matcher m = TEXT.matcher(body);
        return m.matches() ? m.group(1).replace("\\\"", "\"").replace("\\\\", "\\") : null;
    }
}
