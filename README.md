# HookPulse check-in

Know when a scheduled GitHub Actions workflow stops running or fails. Add one step at the end of the job: no secret,
no account and no monitor to create by hand. The first run creates the monitor with the workflow's own schedule;
if a later run fails, or the schedule does not run, [HookPulse](https://hookpulse.net) raises the alert.

GitHub can disable a schedule after 60 days without activity in a public repository, and it delays or drops
scheduled runs under load. Nothing tells you when that happens. This step does.

## Use

```yaml
on:
  schedule:
    - cron: "17 3 * * *"
permissions:
  contents: read
  id-token: write # the step proves which repository it runs in; no secret needed
jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - run: ./backup.sh
      - uses: wrpbr/hookpulse-action@v1
        if: always() # report failures too
        with:
          status: ${{ job.status }}
```

The job summary shows the monitor, its state, the next expected run, a public status page and a badge for your
README.

## Alerts

Choose where a missed or failed run goes:

- A webhook, such as Slack or Discord: keep its address in a secret and pass `alert-url: ${{ secrets.SLACK_WEBHOOK }}`.
- Your e-mail: create a free account on [hookpulse.net](https://hookpulse.net), copy your setup key (`hpk_…`) and
  pass `hookpulse-key: ${{ secrets.HOOKPULSE_KEY }}`. The monitor then belongs to your account, where you can see
  and manage it. A monitor the repository created before moves to your account.

## Inputs

| Input | Default | What it does |
|---|---|---|
| `status` | — | How the job ended. Pass `${{ job.status }}`. Required. |
| `alert-url` | — | Public HTTPS webhook that receives a JSON on a missed or failed run. |
| `hookpulse-key` | — | Your HookPulse setup key, from a secret. |
| `grace-sec` | `3600` | Allowed delay after each scheduled time, 60 to 86400 seconds. Cover the GitHub delay and the job duration. |
| `interval-sec` | — | For a job without a schedule: the tolerated silence, 60 to 86400 seconds. |
| `name` | job id | Name of this job in the monitor, when one workflow has several jobs with this step. |
| `url` | `https://hookpulse.net` | HookPulse address. |
| `fail-on-error` | `false` | Fail this step when HookPulse cannot record the run. By default the step never breaks your job. |

Outputs: `state`, `status-page` and `badge`.

## How it works

The step asks GitHub for the job's OIDC identity token, issued for the HookPulse address only, and sends it with
`status`, the job id and the cron that fired the run (`github.event.schedule`). HookPulse checks the token's
signature with GitHub's public keys, so it knows the repository and the workflow without a secret. The monitor is
`owner/repo/workflow.yml#job`, scheduled in UTC with one hour of allowed delay by default. A `cancelled` run records
nothing. When you edit the cron in the workflow, the next scheduled run updates the monitor.

The answer never carries the monitor's private ID, because the log of a public repository is public. The script is
plain `bash` and `curl`; pin it by commit SHA if your policy requires it.

## Price

Without a key, each repository has ten free monitors. With your key, your account's free tier and plans apply:
https://hookpulse.net/pricing. Check-ins have no charge.

## License

MIT. The HookPulse service follows its [terms of use](https://hookpulse.net/terms) and
[privacy policy](https://hookpulse.net/privacy). Questions: open an issue or write to contato@hookpulse.net.
