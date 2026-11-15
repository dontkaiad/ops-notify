# ops-notify

Копия из heylark-infra, правки только там.

A composite GitHub Action that posts one message to a Telegram ops group (deploy ok / deploy failed / error / ...), with a fixed message template and one topic per project.

- `action.yml`: the action.
- `ops-notify.sh`: the sender and the message templates.
- `topics.env`: project -> topic and emoji table.

No secrets live here. The bot token and the chat id are passed in by the calling repository from its own secrets (`token`, `chat-id` inputs); the token reaches `curl` through stdin, never through a command line.

## Usage

```yaml
- name: Notify (deploy ok)
  uses: dontkaiad/ops-notify@v1
  with:
    project: klgpff          # a key from topics.env
    kind: deploy_ok
    token: ${{ secrets.TG_LOG_BOT_TOKEN }}
    chat-id: ${{ secrets.TG_LOG_CHAT_ID }}

- name: Notify (deploy failed)
  if: failure()
  uses: dontkaiad/ops-notify@v1
  with:
    project: klgpff
    kind: deploy_fail
    title: Deploy over SSH   # the failed step
    token: ${{ secrets.TG_LOG_BOT_TOKEN }}
    chat-id: ${{ secrets.TG_LOG_CHAT_ID }}
```

A notification problem never fails the calling job; the run log prints the result of the send and a `::warning::` when Telegram did not accept the message. `test: 'true'` sends silently, deletes the message again after a few seconds and fails the step if either part failed.
