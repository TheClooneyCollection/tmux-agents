# Explicit long messages and tmux-read

Agents decide when content would flood the receiver's chat. Automatic line limits and paragraph splitting obscure that choice.

Ordinary messages, including `--message-file` alone, are pasted in full and not archived. A positional summary combined with `--message-file PATH` explicitly retains the file and delivers the summary as given plus `Read the full message here: tmux-read <id>`. Both file modes ignore stdin; summaries are positional only to preserve file-only behavior.

Attachments live in the socket state directory for 7 days. Requests reuse their request ID; replies and notices get independent IDs. Any agent or user in a plain shell may read them without connecting to tmux. The receiver decides whether the summary suffices.

Relays add only their own short note and the original pointer line when little or no rewriting is needed. Separate documents are for content that must outlive 7 days or be edited. Spawn briefs and system notices retain their full inline behavior without archiving.
