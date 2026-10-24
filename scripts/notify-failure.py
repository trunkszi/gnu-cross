#!/usr/bin/env python3
"""Send the same classified failure and asset state as the Actions summary."""
from email.message import EmailMessage
import os
import smtplib
import ssl
import sys


def send():
    host = os.environ['SMTP_HOST']
    port = int(os.environ.get('SMTP_PORT') or '587')
    user = os.environ['SMTP_USERNAME']
    message = EmailMessage()
    message['Subject'] = 'gnu-cross ' + os.environ['FAILURE_STAGE']
    message['From'] = os.environ.get('SMTP_FROM') or user
    message['To'] = os.environ['NOTIFY_EMAIL_TO']
    message.set_content(f"{os.environ['FAILURE_STAGE']}\nPublished v0.0.1 Release: {os.environ['PUBLISHED_STATE']}\n"
                        f"Upstream: {os.environ['UPSTREAM_VERSIONS']}\n{os.environ['RUN_URL']}\n")
    context = ssl.create_default_context()
    provider = smtplib.SMTP_SSL if port == 465 else smtplib.SMTP
    kwargs = dict(timeout=30)
    if port == 465:
        kwargs['context'] = context
    with provider(host, port, **kwargs) as smtp:
        if port != 465:
            smtp.starttls(context=context)
        smtp.login(user,os.environ['SMTP_PASSWORD'])
        smtp.send_message(message)


if __name__ == '__main__':
    try:
        send()
    except Exception as exc:
        print(f'::error title=NOTIFY_EMAIL_FAILED::{exc}',file=sys.stderr)
        sys.exit(1)
