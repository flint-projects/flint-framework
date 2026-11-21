/// Form inputs and owned responses.
module flint.prompt.types;

import flint.prompt.secret : Secret;

@safe:

/// One application identity and label in a choice prompt.
struct Choice
{
    /// Value returned on selection.
    string value;
    /// Display label.
    string label;
    /// Show the option while excluding it from submission.
    bool disabled;
}

/// Input policy shared by standalone prompts.
struct FormOptions
{
    /// Require a real terminal before opening the input session.
    bool requireTerminal = true;
    /// Maximum UTF-8 bytes in one response.
    uint maxInputBytes = 4_096;
}

/// An ordered form field supplied by the application.
struct Field
{
    /// Unique key reported in validation feedback.
    string key;
    /// Display title.
    string title;
    /// Reject an empty answer when submitting the page.
    bool required;
    /// Capture input in move-only native storage.
    bool secret;
}

/// An owning answer containing either public text or a native secret.
struct Answer
{
    /// Source field key.
    string key;
    /// Public answer text, empty for a secret.
    string value;
    /// Native answer owner.
    Secret secret;
    /// Whether the answer is secret.
    bool isSecret;
}
