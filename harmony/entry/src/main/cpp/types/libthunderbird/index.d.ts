export const validateEmailAddress: (input: string) => boolean;
export const mimeRequest: (operation: number, input: string) => Promise<string>;
export const jmapAccountRequest: (input: string) => Promise<string>;
export const imapAccountRequest: (input: string) => Promise<string>;
export const smtpAccountRequest: (input: string) => Promise<string>;
export const discoveryRequest: (input: string) => Promise<string>;
export const oauthRequest: (input: string) => Promise<string>;
