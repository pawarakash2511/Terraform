# Trainer Guide — AWS Security Monitoring Lab

This guide is written for the person delivering this material as training.
It explains not just *what* each component does, but *why it exists* and
*what AWS is doing internally* — the depth needed to answer follow-up
questions confidently.

---

## Section 1: Why CloudTrail Is Required

**The concept:** CloudTrail is AWS's audit log for the control plane — every
API call, whether made via console click, CLI command, SDK call, or another
AWS service acting on your behalf, gets recorded as a structured JSON event.

**Why it's foundational:** Without CloudTrail, there is no record that an
action happened at all. You cannot alert on, investigate, or prove
after-the-fact what occurred in an AWS account without it. Every compliance
framework (CIS, SOC 2, PCI-DSS, HIPAA, ISO 27001) treats CloudTrail as a
baseline, non-negotiable control.

**What AWS does internally:** CloudTrail runs as a managed service already
watching your account's control-plane traffic. When you create a "trail"
(the Terraform `aws_cloudtrail` resource), you're not turning on logging
from scratch — you're telling AWS to start persisting and delivering that
already-happening event stream to destinations you specify (S3, and
optionally CloudWatch Logs).

**Talking point for the room:** "CloudTrail is watching by default in most
accounts. What we're doing today isn't turning on a camera — it's telling
AWS where to send the footage, and asking to be tapped on the shoulder when
the footage shows something specific."

---

## Section 2: Why S3 Is Required

**The concept:** S3 is CloudTrail's mandatory, durable log destination.
CloudTrail will not function without an S3 bucket target — it's not
optional infrastructure, it's a hard requirement of the `aws_cloudtrail`
resource.

**Why it's foundational:** Log files need to survive independently of any
compute process, be cheap to store at scale, and be queryable later (via
Athena, for instance) for forensic investigation. S3 satisfies all three.
CloudWatch Logs (Section 3) is comparatively expensive for long-term
retention and isn't designed as a permanent archive.

**What we configure and why:**
- **Public access block** — logs contain sensitive data (IAM identities,
  source IPs, resource names); a publicly readable CloudTrail bucket is one
  of the most damaging cloud misconfigurations possible.
- **Versioning** — protects against accidental or malicious overwrite/delete
  of log objects.
- **Server-side encryption** — data at rest protection, expected by every
  compliance framework.
- **Lifecycle rules** — automatically ages logs into cheaper storage tiers
  and eventually expires them, controlling long-term cost.
- **Bucket policy** — this is the part trainees should look at closely. It's
  a resource-based policy that authorizes *only* the CloudTrail service
  principal, *only* for this specific trail's ARN (via the `aws:SourceArn`
  condition), to write objects under a tightly scoped key prefix.

---

## Section 3: Why CloudWatch Logs Is Required

**The concept:** CloudWatch Logs is what makes CloudTrail data *searchable
and reactive in near real time*. S3 log files are delivered roughly every
5 minutes, in batched, compressed files — not something you can build a
live alerting pipeline against efficiently. CloudWatch Logs receives events
individually, in near real time, and supports metric filters directly.

**What AWS does internally:** For every log delivery, CloudTrail (using the
IAM role we define in `iam.tf`) calls `logs:PutLogEvents` against the log
group we created. This is a second, independent delivery path from the S3
delivery — turning one off doesn't turn off the other, and forgetting to
configure this path (a very common mistake) means S3 keeps filling up fine
while CloudWatch Logs stays completely empty, silently.

**Talking point:** "This is the #1 misconfiguration to know about, if you
only remember one thing from this section: CloudTrail can succeed at
logging to S3 while completely failing at logging to CloudWatch, and
nothing anywhere will tell you that's happening unless you specifically go
check the log group."

---

## Section 4: Why Metric Filters Are Required

**The concept:** A metric filter is a saved pattern that CloudWatch Logs
evaluates against every incoming log line. On a match, it increments a
named metric.

**Why it's the right tool here:** Metric filters are pattern-matching, not
full-text search — they're built to run continuously and cheaply against
a live stream, which is exactly the "is this specific dangerous thing
happening right now" use case. Compare this to CloudWatch Logs Insights,
which is a query tool for *ad hoc* investigation of historical data — the
wrong tool for continuous, automated detection.

**Pattern logic walkthrough (do this live, on screen):**
```
{ ($.eventSource = "s3.amazonaws.com") && ($.eventName = "DeleteBucket") }
```
- `$.eventSource` and `$.eventName` reference fields inside each CloudTrail
  JSON log line.
- `&&` requires both conditions — this narrows the match specifically to
  the S3 service's DeleteBucket action, not any other service's
  similarly-named action.

```
{ ($.eventName = "ConsoleLogin") && ($.userIdentity.type = "Root") }
```
- The second condition here is the critical teaching point: **without it**,
  this filter would match every console login by every IAM user — an alert
  storm, and not what the spec asked for. The `userIdentity.type = "Root"`
  condition is what makes this specifically a *root-only* detector.

---

## Section 5: Why Metrics Are Required

**The concept:** The metric filter produces a *metric* — a named, numeric
time series (`SecurityMonitoring/DeleteBucketEventCount`, in this project).
This is a distinct AWS object from the filter itself; the filter is the
detection logic, the metric is where matched results accumulate.

**Why this two-step design exists:** Separating "detect a pattern" from
"the resulting number" lets CloudWatch Alarms — a completely generic,
reusable service — watch *any* metric, whether it came from a log pattern,
an EC2 CPU reading, or a custom application metric, using identical alarm
logic. This is a deliberate AWS design pattern worth pointing out: metric
filters exist purely to translate unstructured log data into the structured
metric format the rest of CloudWatch already understands.

---

## Section 6: Why Alarms Are Required

**The concept:** An alarm evaluates a metric on a schedule and transitions
between states (`OK`, `ALARM`, `INSUFFICIENT_DATA`) based on a threshold
rule.

**Configuration choices in this project, explained:**
- **Threshold >= 1** — any single occurrence should alert; this is a
  security event, not a performance metric where you'd want to average out
  noise.
- **Period = 60 seconds** — how often the alarm re-evaluates. Shorter means
  faster detection, at a (minor) cost increase.
- **Evaluation periods = 1** — the alarm fires on the very first period
  where the threshold is met; we are not waiting for a sustained trend.
  (Compare to, say, a CPU alarm, where you'd typically want 3 consecutive
  breaching periods to avoid false positives on a brief spike — that
  reasoning does not apply to security events, where even a brief
  occurrence is significant.)
- **`treat_missing_data = "notBreaching"`** — absence of matching events is
  the expected, healthy state. Without this setting, a period with zero
  data points can flip the alarm into `INSUFFICIENT_DATA`, which is a
  common source of false/noisy alerting in real deployments.

---

## Section 7: Why SNS Is Required

**The concept:** SNS is the notification fan-out layer. CloudWatch Alarms
cannot send an email directly — `alarm_actions` can only reference an SNS
topic ARN.

**Why this indirection is useful, not just necessary:** Because the alarm
only knows about the topic, you can add, remove, or change subscribers
(more emails, a Slack integration, a ticketing system) without ever
touching the alarm configuration. This is a good moment to mention: in a
mature setup, this same topic could simultaneously feed a PagerDuty
integration and an audit log Lambda, in addition to email — the alarm
config itself never has to know or care.

**The confirmation step, explained:** AWS requires a human to explicitly
confirm an email subscription before delivery begins. This is intentional
—  it prevents SNS from being usable as a mechanism to spam email addresses
the account owner doesn't actually control. This is also the #1 "nothing is
happening!" support question in real deployments — always check subscription
confirmation status first when troubleshooting.

---

## Section 8: What Happens End-to-End (Full Trace)

Walk the room through this exact sequence for the DeleteBucket scenario,
narrating each arrow:

1. Someone runs `aws s3api delete-bucket --bucket some-bucket`
2. AWS's S3 service processes the deletion and, separately, notifies the
   CloudTrail service of the API call that occurred
3. CloudTrail batches this event and, using the IAM role from `iam.tf`,
   calls `logs:PutLogEvents` to write it into the CloudWatch Log Group
   (this happens within seconds — much faster than the ~5 minute S3
   delivery)
4. CloudWatch Logs evaluates the new log line against every registered
   metric filter pattern
5. The `delete_bucket` filter's pattern matches; CloudWatch increments the
   `SecurityMonitoring/DeleteBucketEventCount` metric by 1
6. On its next 60-second evaluation cycle, the `delete_bucket` alarm sees
   `Sum >= 1` and transitions from `OK` to `ALARM`
7. That state transition invokes the alarm's `alarm_actions`, calling
   `sns:Publish` against the security-alerts topic
8. SNS delivers the message to every confirmed email subscription
9. A human receives an email and investigates

**Total elapsed time in practice:** typically 1–3 minutes from action to
inbox.

---

## Section 9: Delivery Tips

- Have a sandbox account ready and **test both trigger scenarios yourself**
  the day before — root login specifically requires actual root credentials,
  which not every sandbox has readily available; plan for this in advance.
- The most common "why isn't this working" moments, in order of frequency:
  1. SNS email not confirmed
  2. Testing in a region different from where the trail/log group live
     (though the trail is multi-region, the log group and alarms are
     regional — this is worth clarifying if asked)
  3. Impatience — CloudWatch Logs delivery from CloudTrail is fast (seconds)
     but not instant; alarms only re-evaluate on their period (60s here)
- Keep a second terminal open running `aws logs tail <log-group> --follow`
  during the live demo — watching raw JSON events arrive in real time is a
  genuinely effective visual aid for a non-Terraform-fluent audience.
