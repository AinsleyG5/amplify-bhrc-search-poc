import { LightningElement, api } from 'lwc';

/**
 * csBrand: Amplify logo. Shows logoUrl when set (for example /resource/AmplifyLogo or a public File URL),
 * otherwise a text wordmark. tone: 'light' (on dark backgrounds) or 'dark'.
 */
export default class CsBrand extends LightningElement {
    @api logoUrl;
    @api tone = 'light';
    @api compact = false;

    get hasLogo() {
        return !!this.logoUrl;
    }

    get cls() {
        return `brand brand-${this.tone === 'dark' ? 'dark' : 'light'}${this.compact ? ' compact' : ''}`;
    }
}
