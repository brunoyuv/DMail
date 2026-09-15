// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { Mail } from './Mail';

function sample(id: string, name: string, address: string, subject: string, body: string,
  minutesAgo: number, unread: boolean, starred: boolean): Mail {
  const mail = new Mail();
  mail.id = id;
  mail.messageId = `${id}@example.com`;
  mail.threadId = id;
  mail.fromName = name;
  mail.fromAddress = address;
  mail.to = 'you@example.com';
  mail.subject = subject;
  mail.body = body;
  mail.receivedAt = Date.now() - minutesAgo * 60000;
  mail.unread = unread;
  mail.starred = starred;
  return mail;
}

export function sampleMailbox(): Mail[] {
  return [
    sample('welcome', 'D-Mail', 'hello@example.com', 'A little more space for your mail',
      'Welcome to D-Mail for HarmonyOS.\n\nThis is a sample mailbox. You can read messages, search, star, archive, and write drafts. Your changes stay on this device.\n\nConnecting an email account and sending messages will arrive in a later build.\n\nMake yourself at home.', 5, true, false),
    sample('weekend', 'Alex Chen', 'alex@example.com', 'A slow Saturday?',
      'Hey,\n\nThere’s a new café near the riverside. Shall we grab a coffee this weekend and take the long way home?\n\nNo rush. Let me know what works for you.\n\nAlex', 42, true, true),
    sample('notes', 'Design team', 'design@example.com', 'Notes from our last conversation',
      'A few things we agreed on:\n\nKeep the inbox quiet. Make the everyday actions easy to find. Let the system handle familiar navigation and controls.\n\nThe small details make the difference.\n\nThanks everyone!', 180, false, false),
    sample('trip', 'Jamie Park', 'jamie@example.com', 'The route is ready',
      'Hi,\n\nI found a walking route along the coast. There are a few good places to stop, and the last train leaves well after sunset.\n\nI’ll bring the map. You bring the playlist.\n\nJamie', 1380, false, false),
    sample('community', 'Community', 'community@example.com', 'Built together, one step at a time',
      'Hello,\n\nOpen source starts with people sharing ideas, testing the details, and making something useful together.\n\nThank you for trying this early HarmonyOS port.\n\nThe community', 2760, false, true)
  ];
}
