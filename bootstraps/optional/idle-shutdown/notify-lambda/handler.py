import json
import os
import time
import uuid
import urllib.request
import boto3

# Timeout for external HTTP calls (seconds)
HTTP_TIMEOUT = 10


def handler(event, context):
    instance_id = event['detail']['instance-id']
    state = event['detail']['state']
    event_id = event.get('id', '')  # EventBridge event ID for logging

    target_instance = os.environ.get('INSTANCE_ID')
    if target_instance and instance_id != target_instance:
        return

    ssm = boto3.client('ssm')

    # Load Telegram credentials — fail fast if unavailable
    try:
        telegram_token = ssm.get_parameter(
            Name='/openclaw/wake-config/telegram-bot-token', WithDecryption=True
        )['Parameter']['Value']
    except Exception as e:
        print(f"FATAL: Cannot load Telegram token from SSM: {e}")
        raise

    chat_id = os.environ['TELEGRAM_CHAT_ID']
    wake_url = os.environ.get('WAKE_URL', '')

    if state == 'running':
        ec2 = boto3.client('ec2')

        # Retry for public IP — can arrive after running event
        public_ip = None
        for attempt in range(3):
            try:
                response = ec2.describe_instances(InstanceIds=[instance_id])
                public_ip = response['Reservations'][0]['Instances'][0].get('PublicIpAddress')
            except Exception as e:
                print(f"WARNING: DescribeInstances attempt {attempt+1} failed: {e}")
            if public_ip:
                break
            if attempt < 2:
                time.sleep(5)

        if not public_ip:
            # Send fallback notification — don't leave user without any signal
            try:
                fallback_body = json.dumps({
                    'chat_id': chat_id,
                    'text': '🟡 Machine is running but public IP not available yet. Check again in a moment.',
                    'disable_web_page_preview': True
                }).encode()
                fallback_req = urllib.request.Request(
                    f"https://api.telegram.org/bot{telegram_token}/sendMessage",
                    data=fallback_body,
                    headers={'Content-Type': 'application/json'}
                )
                urllib.request.urlopen(fallback_req, timeout=HTTP_TIMEOUT)
            except Exception as e:
                print(f"WARNING: Fallback Telegram notification failed: {e}")
            print(f"event_id={event_id} — no public IP after 3 attempts, sent fallback")
            return

        message = (
            f"🟢 Machine is up and running\n\n"
            f"Public IP: {public_ip}\n\n"
            f"ssh ec2-user@{public_ip}"
        )

    elif state == 'stopped':
        token_param = '/openclaw/wake-token'

        # Guard: verify instance is actually stopped before rotating token.
        # A delayed/out-of-order stopped event can arrive after a successful wake.
        try:
            ec2_check = boto3.client('ec2')
            check_resp = ec2_check.describe_instances(InstanceIds=[instance_id])
            actual_state = check_resp['Reservations'][0]['Instances'][0]['State']['Name']
            if actual_state not in ('stopped', 'stopping'):
                print(f"event_id={event_id} — stale stopped event, instance is actually {actual_state}")
                return
        except Exception as e:
            # FAIL CLOSED: can't confirm instance is stopped — don't rotate token
            print(f"WARNING: EC2 state check failed — not rotating token (fail closed): {e}")
            return

        # Deduplicate stop events — EventBridge is at-least-once.
        dedup_param = '/openclaw/wake-config/last-stop-event-id'
        if event_id:
            try:
                last_event = ssm.get_parameter(Name=dedup_param)['Parameter']['Value']
                if last_event == event_id:
                    print(f"event_id={event_id} — duplicate stopped event, skipping token rotation")
                    return
            except ssm.exceptions.ParameterNotFound:
                pass
            except Exception as e:
                print(f"WARNING: Dedup check failed (continuing): {e}")

        # Always generate a fresh token on stop — prevents stale token reuse
        token = str(uuid.uuid4())
        ssm.put_parameter(Name=token_param, Value=token,
                          Type='String', Overwrite=True)
        token_status = "✅ Fresh wake token generated."

        # Record this event ID for dedup
        if event_id:
            try:
                ssm.put_parameter(Name=dedup_param, Value=event_id,
                                  Type='String', Overwrite=True)
            except Exception as e:
                print(f"WARNING: Dedup marker write failed: {e}")

        wake_link = f"{wake_url}?token={token}"
        message = (
            f"🔴 Machine is shut down.\n\n"
            f"{token_status}\n\n"
            f"👉 Tap to wake me up:\n{wake_link}"
        )

    else:
        return

    # Telegram notification — best effort
    try:
        tg_body = json.dumps({
            'chat_id': chat_id,
            'text': message,
            'disable_web_page_preview': True
        }).encode()
        tg_req = urllib.request.Request(
            f"https://api.telegram.org/bot{telegram_token}/sendMessage",
            data=tg_body,
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(tg_req, timeout=HTTP_TIMEOUT)
    except Exception as e:
        print(f"WARNING: Telegram notification failed: {e}")

    print(f"event_id={event_id} state={state} — notification sent")
    return {'state': state, 'event_id': event_id}
