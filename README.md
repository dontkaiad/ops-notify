# ops-notify

Telegram ops alerts action.

A composite GitHub Action that posts one templated message to a Telegram chat topic from CI.

## Usage

```yaml
- name: Notify (deploy ok)
  uses: dontkaiad/ops-notify@v1
  with:
    project: myapp          # a key from topics.env
    kind: deploy_ok
    token: ${{ secrets.TG_BOT_TOKEN }}
    chat-id: ${{ secrets.TG_CHAT_ID }}

- name: Notify (deploy failed)
  if: failure()
  uses: dontkaiad/ops-notify@v1
  with:
    project: myapp
    kind: deploy_fail
    title: Deploy step      # the failed step
    token: ${{ secrets.TG_BOT_TOKEN }}
    chat-id: ${{ secrets.TG_CHAT_ID }}
```

The bot token and the chat id come from the caller's own secrets; nothing secret lives here. A notification problem never fails the calling job. `test: 'true'` sends silently, deletes the message again after a few seconds and fails the step if either part failed.
