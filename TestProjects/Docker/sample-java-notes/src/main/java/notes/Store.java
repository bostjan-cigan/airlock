package notes;

import java.sql.*;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/** Notes in Postgres. */
public final class Store implements AutoCloseable {
    public record Note(int id, String text) {
        String json() {
            return "{\"id\":" + id + ",\"text\":" + Json.quote(text) + "}";
        }
    }

    private final Connection connection;

    public Store(Config config) throws SQLException {
        connection = DriverManager.getConnection(config.databaseUrl(), config.databaseUser(), config.databasePassword());
        try (Statement s = connection.createStatement()) {
            s.execute("CREATE TABLE IF NOT EXISTS notes (id SERIAL PRIMARY KEY, text TEXT NOT NULL)");
        }
    }

    public synchronized void truncate() throws SQLException {
        try (Statement s = connection.createStatement()) { s.execute("TRUNCATE notes RESTART IDENTITY"); }
    }

    public synchronized boolean ping() {
        try (Statement s = connection.createStatement()) { return s.execute("SELECT 1"); } catch (SQLException e) { return false; }
    }

    public synchronized List<Note> list() throws SQLException {
        List<Note> notes = new ArrayList<>();
        try (Statement s = connection.createStatement(); ResultSet rows = s.executeQuery("SELECT id, text FROM notes ORDER BY id")) {
            while (rows.next()) notes.add(new Note(rows.getInt(1), rows.getString(2)));
        }
        return notes;
    }

    public synchronized Optional<Note> get(int id) throws SQLException {
        try (PreparedStatement s = connection.prepareStatement("SELECT id, text FROM notes WHERE id = ?")) {
            s.setInt(1, id);
            try (ResultSet rows = s.executeQuery()) {
                return rows.next() ? Optional.of(new Note(rows.getInt(1), rows.getString(2))) : Optional.empty();
            }
        }
    }

    public synchronized Note insert(String text) throws SQLException {
        try (PreparedStatement s = connection.prepareStatement("INSERT INTO notes (text) VALUES (?) RETURNING id, text")) {
            s.setString(1, text);
            try (ResultSet rows = s.executeQuery()) {
                rows.next();
                return new Note(rows.getInt(1), rows.getString(2));
            }
        }
    }

    public synchronized int count() throws SQLException {
        try (Statement s = connection.createStatement(); ResultSet rows = s.executeQuery("SELECT count(*) FROM notes")) {
            rows.next();
            return rows.getInt(1);
        }
    }

    @Override public void close() throws SQLException { connection.close(); }
}
