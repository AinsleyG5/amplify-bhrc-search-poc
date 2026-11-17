import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';

import getEnrichmentSource from '@salesforce/apex/RecordEnrichmentController.getEnrichmentSource';
import analyzeTranscript from '@salesforce/apex/EnrichmentSkillPromptService.analyzeTranscript';
import findContactCandidates from '@salesforce/apex/MarketIntelligenceController.findContactCandidates';
import findJobsForCandidate from '@salesforce/apex/MarketIntelligenceController.findJobsForCandidate';
import applyContactFieldUpdates from '@salesforce/apex/EnrichmentApplyController.applyContactFieldUpdates';
import applySkillUpdates from '@salesforce/apex/EnrichmentApplyController.applySkillUpdates';
import createJobLead from '@salesforce/apex/EnrichmentApplyController.createJobLead';
import logEnrichment from '@salesforce/apex/EnrichmentApplyController.logEnrichment';
import createPowerNote from '@salesforce/apex/EnrichmentApplyController.createPowerNote';

import parseResume from '@salesforce/apex/TxLLMResumeParserController.parseResume';
import getLatestContentVersionId from '@salesforce/apex/TxLLMResumeParserController.getLatestContentVersionId';

const SKILL_CAP = 5;
const ACCEPTED_FILE_TYPES = ['.pdf', '.docx', '.doc'];
const PASTE_MIN_LENGTH = 50;

export default class AmplifyRecordEnrichmentPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    
    // Source loading
    sourceLoading = true;
    sourceData;
    sourceError;
    
    // Enrichment flow
    enrichmentLoading = false;
    hasEnriched = false;
    
    // Suggestions data
    suggestedUpdates = [];
    recordHints = [];
    warnings = [];
    updatesExpanded = true;
    applyingUpdates = false;
    
    // Market Intelligence Summary
    marketIntelligenceSummary = '';
    marketIntelligenceKeyPoints = [];
    saveAsPowerNote = false;
    
    // Resolved anchors
    resolvedContactId;
    resolvedJobId;
    
    // Inferred entities
    inferredPersonName = '';
    inferredPersonSubtitle = '';
    inferredPersonCompany = '';
    inferredJobName = '';
    inferredJobCompany = '';
    
    // Confirmation state
    personConfirmation = 'unset';
    currentRecordName = '';
    showReRunConfirmation = false;
    
    // Alternative input state
    inputMode = 'upload'; // 'upload' | 'paste'
    documentParsing = false;
    uploadedDocumentName = '';
    pastedNoteText = '';
    
    // ============================================================
    // Wires
    // ============================================================
    @wire(getRecord, { recordId: '$recordId', fields: '$nameFieldForCurrentRecord' })
    wiredRecord({ data }) {
        if (data) {
            const nameField = this.nameFieldForCurrentRecord?.[0];
            if (nameField) {
                this.currentRecordName = getFieldValue(data, nameField) || '';
            }
        }
    }
    
    get nameFieldForCurrentRecord() {
        if (!this.objectApiName) return [];
        const fieldName = (this.objectApiName === 'Task' || this.objectApiName === 'Event')
            ? 'Subject'
            : 'Name';
        return [`${this.objectApiName}.${fieldName}`];
    }
    
    // ============================================================
    // Lifecycle
    // ============================================================
    connectedCallback() {
        this.loadEnrichmentSource();
    }
    
    async loadEnrichmentSource() {
        this.sourceLoading = true;
        this.sourceError = null;
        try {
            this.sourceData = await getEnrichmentSource({
                recordId: this.recordId,
                objectApiName: this.objectApiName
            });
            this.resolvedContactId = this.sourceData.derivedContactId;
            this.resolvedJobId = this.sourceData.derivedJobId;
        } catch (e) {
            this.sourceError = this.normalizeError(e);
        } finally {
            this.sourceLoading = false;
        }
    }
    
    // ============================================================
    // State visibility getters
    // ============================================================
    get showPreEnrichmentState() {
        return !this.sourceLoading 
            && !this.sourceError
            && !this.hasEnriched 
            && !this.enrichmentLoading 
            && this.sourceData?.hasContent === true
            && !this.hasPreviousEnrichment;
    }
    
    get showPreviouslyEnrichedState() {
        return !this.sourceLoading
            && !this.sourceError
            && !this.hasEnriched
            && !this.enrichmentLoading
            && this.sourceData?.hasContent === true
            && this.hasPreviousEnrichment;
    }
    
    get showNoContentState() {
        return !this.sourceLoading 
            && !this.sourceError
            && !this.hasEnriched
            && !this.enrichmentLoading
            && this.sourceData
            && this.sourceData.hasContent === false;
    }
    
    get showAlternativeInput() {
        // Show paste/upload options on Contact pages
        return this.objectApiName === 'Contact';
    }
    
    get isUploadMode() {
        return this.inputMode === 'upload';
    }
    
    get isPasteMode() {
        return this.inputMode === 'paste';
    }
    
    get uploadButtonVariant() {
        return this.isUploadMode ? 'brand' : 'neutral';
    }
    
    get pasteButtonVariant() {
        return this.isPasteMode ? 'brand' : 'neutral';
    }
    
    // ============================================================
    // Content getters
    // ============================================================
    get preEnrichmentMessage() {
        return 'Amplify will analyse this record and suggest updates across your CRM.';
    }
    
    get noContentMessage() {
        return this.sourceData?.sourceLabel || 'This record has no content to enrich yet.';
    }
    
    get sourceLabelDisplay() {
        return this.sourceData?.sourceLabel || '';
    }
    
    get wasTruncated() {
        return this.sourceData?.wasTruncated === true;
    }
    
    get enrichDisabled() {
        return this.enrichmentLoading || !this.sourceData?.hasContent;
    }
    
    get documentUploadDisabled() {
        return this.enrichmentLoading || this.documentParsing;
    }
    
    get pasteEnrichDisabled() {
        return this.enrichmentLoading 
            || !this.pastedNoteText 
            || this.pastedNoteText.trim().length < PASTE_MIN_LENGTH;
    }
    
    get acceptedFileTypes() {
        return ACCEPTED_FILE_TYPES;
    }
    
    get hasSuggestedUpdates() {
        return this.suggestedUpdates?.length > 0;
    }
    
    get hasRecordHints() {
        return this.recordHints?.length > 0;
    }
    
    get hasMarketIntelligenceSummary() {
        return !!this.marketIntelligenceSummary;
    }

    get hasKeyPoints() {
        return this.marketIntelligenceKeyPoints?.length > 0;
    }
    
    get suggestedCount() {
        return this.suggestedUpdates?.length || 0;
    }
    
    get recordUpdatesTitle() {
        const count = this.suggestedCount;
        const label = count === 1 ? 'Record Update' : 'Record Updates';
        return `${count} ${label}`;
    }
    
    get expandCollapseIcon() {
        return this.updatesExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }
    
    get allSelected() {
        if (!this.hasSuggestedUpdates) return false;
        return this.suggestedUpdates.every(row => row.selected);
    }
    
    get noRowsSelected() {
        if (!this.hasSuggestedUpdates) return true;
        return !this.suggestedUpdates.some(row => row.selected);
    }
    
    get disableUpdateSelected() {
        return this.noRowsSelected || this.applyingUpdates;
    }
    
    get disableUpdateAll() {
        return !this.hasSuggestedUpdates || this.applyingUpdates;
    }
    
    get showInferredPersonCard() {
        const cfg = this.sourceData?.config;
        return cfg?.resolvePerson === true && !!this.inferredPersonName;
    }
    
    get showInferredJobCard() {
        const cfg = this.sourceData?.config;
        return cfg?.resolveJob === true && !!(this.inferredJobName);
    }
    
    get showPersonMismatchWarning() {
        if (this.objectApiName !== 'Contact') return false;
        if (!this.inferredPersonName || !this.currentRecordName) return false;
        return !this.fuzzyNameMatch(this.inferredPersonName, this.currentRecordName);
    }
    
    get thumbUpVariant() {
        return this.personConfirmation === 'up' ? 'brand' : 'border';
    }
    
    get thumbDownVariant() {
        return this.personConfirmation === 'down' ? 'destructive' : 'border';
    }
    
    get hasPreviousEnrichment() {
        return !!this.sourceData?.lastEnrichedAt;
    }
    
    get lastEnrichedDisplay() {
        if (!this.sourceData?.lastEnrichedAt) return '';
        
        const then = new Date(this.sourceData.lastEnrichedAt);
        const now = new Date();
        const diffMs = now - then;
        const diffMins = Math.floor(diffMs / 60000);
        const diffHours = Math.floor(diffMs / 3600000);
        const diffDays = Math.floor(diffMs / 86400000);
        
        if (diffMins < 1) return 'just now';
        if (diffMins < 60) return `${diffMins} minute${diffMins === 1 ? '' : 's'} ago`;
        if (diffHours < 24) return `${diffHours} hour${diffHours === 1 ? '' : 's'} ago`;
        if (diffDays < 30) return `${diffDays} day${diffDays === 1 ? '' : 's'} ago`;
        return then.toLocaleDateString();
    }
    
    get lastEnrichmentSummary() {
        const count = this.sourceData?.lastEnrichmentCount;
        if (count == null) return '';
        return `${count} update${count === 1 ? '' : 's'} were applied.`;
    }
    
    // ============================================================
    // Input mode toggle handlers
    // ============================================================
    handleSelectUpload() {
        this.inputMode = 'upload';
    }
    
    handleSelectPaste() {
        this.inputMode = 'paste';
    }
    
    handlePastedNoteChange(event) {
        this.pastedNoteText = event.target.value;
    }
    
    handleSummaryChange(event) {
        this.marketIntelligenceSummary = event.target.value;
    }
    
    handleTogglePowerNoteSave(event) {
        this.saveAsPowerNote = event.target.checked;
    }
    
    // ============================================================
    // Enrichment entry points
    // ============================================================
    async handleEnrichClick() {
        if (!this.sourceData?.transcript) return;
        
        this.enrichmentLoading = true;
        this.hasEnriched = false;
        
        try {
            const raw = await analyzeTranscript({ 
                transcriptText: this.sourceData.transcript,
                enrichmentSubject: this.currentRecordName  // already in state from the wire
            });
            await this.processEnrichmentResponse(raw);
        } catch (e) {
            this.showToast('Enrichment failed', this.normalizeError(e), 'error');
        } finally {
            this.enrichmentLoading = false;
        }
    }
    
    async handleEnrichFromPastedNote() {
        const trimmed = (this.pastedNoteText || '').trim();
        if (trimmed.length < PASTE_MIN_LENGTH) {
            this.showToast(
                'Note too short',
                `Please paste at least ${PASTE_MIN_LENGTH} characters for a useful enrichment.`,
                'warning'
            );
            return;
        }
        
        // Ensure we have a contact anchor
        if (!this.resolvedContactId && this.objectApiName === 'Contact') {
            this.resolvedContactId = this.recordId;
        }
        
        if (!this.resolvedContactId) {
            this.showToast(
                'Contact required',
                'Paste enrichment requires a contact context.',
                'warning'
            );
            return;
        }
        
        this.enrichmentLoading = true;
        this.hasEnriched = false;
        
        try {
            const raw = await analyzeTranscript({ 
                transcriptText: trimmed,
                enrichmentSubject: this.currentRecordName  // already in state from the wire
            });
            await this.processEnrichmentResponse(raw);
            
            // Override source label for audit log
            if (this.sourceData) {
                const charCount = trimmed.length;
                this.sourceData = {
                    ...this.sourceData,
                    sourceLabel: `Pasted note — ${charCount.toLocaleString()} characters`,
                    sourceItemCount: 1
                };
            }
        } catch (e) {
            this.showToast('Enrichment failed', this.normalizeError(e), 'error');
        } finally {
            this.enrichmentLoading = false;
        }
    }
    
    async handleDocumentUpload(event) {
        const uploadedFiles = event.detail.files;
        if (!uploadedFiles?.length) return;
        
        const file = uploadedFiles[0];
        const contentDocumentId = file.documentId;
        this.uploadedDocumentName = file.name;
        
        if (!this.resolvedContactId && this.objectApiName === 'Contact') {
            this.resolvedContactId = this.recordId;
        }
        
        if (!this.resolvedContactId) {
            this.showToast(
                'Contact required',
                'Document enrichment requires a contact context.',
                'warning'
            );
            return;
        }
        
        this.documentParsing = true;
        this.enrichmentLoading = true;
        this.hasEnriched = false;
        
        try {
            const contentVersionId = await getLatestContentVersionId({ contentDocumentId });
            if (!contentVersionId) {
                throw new Error('Could not resolve ContentVersionId from uploaded file.');
            }
            
            const nowIso = new Date().toISOString().split('T')[0];
            const parseResult = await parseResume({
                documentBase64: null,
                contentVersionId: contentVersionId,
                documentLastModified: nowIso,
                fileName: this.uploadedDocumentName,
                useLLMParser: true,
                normaliseSkills: true,
                normaliseProfessions: true
            });
            
            if (!parseResult?.rawJson) {
                throw new Error('CV parser returned no data.');
            }
            
            const documentText = this.buildTranscriptFromParsedResume(parseResult);
            if (!documentText || documentText.trim().length < PASTE_MIN_LENGTH) {
                throw new Error('Could not extract usable text from the uploaded document.');
            }

            const raw = await analyzeTranscript({ 
                transcriptText: documentText,
                enrichmentSubject: this.currentRecordName
            });
            
            await this.processEnrichmentResponse(raw, { 
                isDocumentSource: true,
                capSkills: true
            });
            
            if (this.sourceData) {
                this.sourceData = {
                    ...this.sourceData,
                    sourceLabel: `Uploaded document: ${this.uploadedDocumentName}`,
                    sourceItemCount: 1
                };
            }
            
            this.showToast(
                'Document parsed',
                `Extracted ${this.suggestedUpdates.length} suggestion(s) from ${this.uploadedDocumentName}`,
                'success'
            );
        } catch (e) {
            console.error('[Enrichment] Document parse failed:', e);
            this.showToast('Document parse failed', this.normalizeError(e), 'error');
        } finally {
            this.documentParsing = false;
            this.enrichmentLoading = false;
        }
    }
    
    // ============================================================
    // Shared response pipeline
    // ============================================================
    async processEnrichmentResponse(raw, options = {}) {
        console.log('[DEBUG] Raw response:', raw);
        console.log('[DEBUG] Raw type:', typeof raw);
        
        let parsed;
        try {
            parsed = this.parseModelJson(raw);
            console.log('[DEBUG] Parsed object:', parsed);
            console.log('[DEBUG] updates array:', parsed?.updates);
            console.log('[DEBUG] updates length:', parsed?.updates?.length);
            console.log('[DEBUG] recordHints length:', parsed?.recordHints?.length);
            console.log('[DEBUG] summary:', parsed?.summary);
        } catch (e) {
            console.error('[DEBUG] Parse failed:', e);
            console.error('[DEBUG] Raw text was:', raw);
            throw e;
        }
        
        this.recordHints = this.mapHints(parsed);
        console.log('[DEBUG] Mapped hints:', this.recordHints);
        
        let rows = this.mapUpdatesToRows(parsed);
        console.log('[DEBUG] Mapped rows:', rows);
        console.log('[Enrichment] Rows treated as skills:', JSON.stringify(rows.filter(r => this.isSkillRow(r)).map(r => r.raw.proposedValue)));
        
        if (options.capSkills) {
            rows = this.capSkillsToTopN(rows, SKILL_CAP);
        }
        this.suggestedUpdates = rows;
        
        this.warnings = parsed.warnings || [];
        this.marketIntelligenceSummary = parsed?.summary?.narrative || '';
        this.marketIntelligenceKeyPoints = parsed?.summary?.keyPoints || [];
        this.saveAsPowerNote = !!this.marketIntelligenceSummary;
        
        console.log('[DEBUG] hasSuggestedUpdates will be:', this.suggestedUpdates?.length > 0);
        console.log('[DEBUG] hasEnriched setting to true');
        
        this.setInferredPersonFromHints();
        this.setInferredJobFromHints();
        
        const cfg = this.sourceData?.config;
        if (cfg?.resolvePerson && !this.resolvedContactId) await this.resolveContactFromHints();
        if (cfg?.resolveJob && !this.resolvedJobId) await this.resolveJobFromHints();
        
        this.hasEnriched = true;
    }
    
    // ============================================================
    // Model output parsing
    // ============================================================
    parseModelJson(rawText) {
        let text = (rawText || '').trim();
        text = text.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
        if (!text.startsWith('{')) text = '{' + text;
        if (!text.endsWith('}')) text = text + '}';
        return JSON.parse(text);
    }
    
    mapUpdatesToRows(parsed) {
        const updates = parsed?.updates || [];
        
        return updates.map((u, idx) => {
            const updateType = u.updateType || 'Field Update';
            const typeUi = this.updateTypeToUi(updateType);
            const conf = typeUi || this.confidenceToUi(u.confidence);
            
            const proposed = (u.proposedValue === null || u.proposedValue === undefined)
                ? ''
                : String(u.proposedValue);
            
            return {
                id: `${u.key || 'k'}-${u.targetField || 'f'}-${idx}`,
                label: this.formatFieldLabel(u.targetField),
                updateType,
                isLeadCreation: updateType.toLowerCase() === 'lead',
                currentValue: 'N/A',
                proposedValue: proposed,
                confidenceLabel: conf.label,
                confidenceClass: conf.css,
                selected: conf.autoSelect,
                raw: u
            };
        });
    }
    
    mapHints(parsed) {
        const hints = parsed?.recordHints || [];
        
        return hints.map((h, idx) => {
            const c = Number(h.confidence || 0);
            const confidenceLabel = c >= 0.85 ? 'High' : c >= 0.60 ? 'Medium' : 'Low';
            const confidenceClass = c >= 0.85 ? 'pill pill-high' 
                : c >= 0.60 ? 'pill pill-medium' 
                : 'pill pill-low';
            
            return {
                id: `${h.entityType || 'Other'}-${idx}`,
                entityType: h.entityType || 'Other',
                value: h.value || '',
                confidence: c,
                confidenceLabel,
                confidenceClass
            };
        });
    }
    
    confidenceToUi(confidence) {
        const c = Number(confidence || 0);
        if (c >= 0.85) return { label: 'High', css: 'pill pill-high', autoSelect: true };
        if (c >= 0.60) return { label: 'Medium', css: 'pill pill-medium', autoSelect: false };
        return { label: 'Low', css: 'pill pill-low', autoSelect: false };
    }
    
    updateTypeToUi(updateType) {
        switch ((updateType || '').toLowerCase()) {
            case 'stage update':
                return { label: 'Stage Change', css: 'pill pill-stage', autoSelect: true };
            case 'lead':
                return { label: 'New Lead', css: 'pill pill-lead', autoSelect: true };
            default:
                return null;
        }
    }
    
    formatFieldLabel(apiName) {
        if (!apiName) return '';
        return apiName
            .replace(/__c$/i, '')
            .replace(/_/g, ' ')
            .replace(/\b\w/g, c => c.toUpperCase());
    }
    
    capSkillsToTopN(rows, n) {
        if (!rows?.length) return rows;
        
        const isSkillRow = r => this.isSkillRow(r);
        
        const skillRows = rows.filter(isSkillRow);
        const nonSkillRows = rows.filter(r => !isSkillRow(r));
        
        if (skillRows.length <= n) return rows;
        
        const sortedSkills = [...skillRows].sort((a, b) => {
            const ca = Number(a.raw?.confidence || 0);
            const cb = Number(b.raw?.confidence || 0);
            return cb - ca;
        });
        
        return [...nonSkillRows, ...sortedSkills.slice(0, n)];
    }
    
    isSkillRow(row) {
        const field = (row?.raw?.targetField || '').toLowerCase();
        const type = (row?.raw?.updateType || '').toLowerCase();
        const target = (row?.raw?.targetObject || '').toLowerCase();
        return type === 'skill' || target === 'tr1__skills__c' || field.includes('skill');
    }

    /** One request per skill name. A value may hold several names separated by commas, semicolons or new lines. */
    buildSkillRequests(rows) {
        const seen = new Set();
        const out = [];
        rows.filter(r => this.isSkillRow(r)).forEach(r => {
            const raw = r.raw || {};
            const values = Array.isArray(raw.proposedValue)
                ? raw.proposedValue
                : String(raw.proposedValue ?? '').split(/[\n;,]+/);
            const quotes = (raw.evidence || []).map(e => e?.quote).filter(Boolean).join(' ');
            const hint = [raw.skillType, raw.category, raw.subType, raw.notes].filter(Boolean).join(' ');
            values
                .map(v => (v && typeof v === 'object') ? (v.name || v.skill || '') : v)
                .map(v => String(v ?? '').trim())
                .filter(Boolean)
                .forEach(name => {
                    const key = name.toLowerCase();
                    if (seen.has(key)) return;
                    seen.add(key);
                    // The model often shortens "Certified Forklift Operator" to "Forklift Operator", so offer the fuller wording too
                    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                    const fuller = quotes.match(new RegExp(`certified\\s+${escaped}`, 'i'));
                    out.push({
                        name,
                        altName: fuller ? fuller[0] : null,
                        skillType: /certif|licen[cs]e|ticket/i.test(`${hint} ${name} ${fuller ? fuller[0] : ''}`) ? 'Certification' : null
                    });
                });
        });
        return out;
    }

    // ============================================================
    // Inferred entity setup
    // ============================================================
    setInferredPersonFromHints() {
        const person = this.recordHints.find(h => h.entityType.toLowerCase() === 'person');
        this.inferredPersonName = person?.value || '';
        
        const email = this.getHintValue('Email');
        const phone = this.getHintValue('Phone');
        this.inferredPersonSubtitle = email || phone || '';
    }
    
    setInferredJobFromHints() {
        const job = this.recordHints.find(h => h.entityType.toLowerCase() === 'job');
        const company = this.recordHints.find(h => h.entityType.toLowerCase() === 'company');
        this.inferredJobName = job?.value || '';
        this.inferredJobCompany = company?.value || '';
    }
    
    getHintValue(type) {
        const h = this.recordHints.find(x => (x.entityType || '').toLowerCase() === type.toLowerCase());
        return h?.value || null;
    }
    
    async resolveContactFromHints() {
        const personName = this.getHintValue('Person');
        const email = this.getHintValue('Email');
        const phone = this.getHintValue('Phone');
        
        if (!personName && !email && !phone) return;
        
        try {
            const candidates = await findContactCandidates({ personName, email, phone });
            const best = candidates?.length ? candidates[0] : null;
            
            if (best && best.score >= 60) {
                this.resolvedContactId = best.id;
                this.inferredPersonCompany = best.currentEmployer || this.inferredPersonCompany;
                this.personConfirmation = 'up';
            }
        } catch (e) {
            console.warn('Contact resolution failed', e);
        }
    }
    
    async resolveJobFromHints() {
        if (!this.resolvedContactId) return;
        
        const jobTitle = this.getHintValue('Job');
        const company = this.getHintValue('Company');
        
        if (!jobTitle && !company) return;
        
        try {
            const results = await findJobsForCandidate({
                contactId: this.resolvedContactId,
                jobTitle,
                companyName: company
            });
            
            const best = results?.length ? results[0] : null;
            if (best) {
                this.resolvedJobId = best.value;
                this.inferredJobName = best.label;
                this.inferredJobCompany = best.accountName || this.inferredJobCompany;
            }
        } catch (e) {
            console.warn('Job resolution failed', e);
        }
    }
    
    // ============================================================
    // Row interaction
    // ============================================================
    toggleUpdatesCollapsed() {
        this.updatesExpanded = !this.updatesExpanded;
    }
    
    handleToggleRow(event) {
        const rowId = event.target.dataset.id;
        const isChecked = event.target.checked;
        this.suggestedUpdates = this.suggestedUpdates.map(row =>
            row.id === rowId ? { ...row, selected: isChecked } : row
        );
    }
    
    handleToggleUpdateAll(event) {
        const isChecked = event.target.checked;
        this.suggestedUpdates = this.suggestedUpdates.map(row => ({
            ...row,
            selected: isChecked
        }));
    }
    
    handleThumbUp() {
        this.personConfirmation = this.personConfirmation === 'up' ? 'unset' : 'up';
    }
    
    handleThumbDown() {
        this.personConfirmation = this.personConfirmation === 'down' ? 'unset' : 'down';
    }
    
    // ============================================================
    // Apply handlers
    // ============================================================
    handleApplySelected() {
        const selected = this.suggestedUpdates.filter(r => r.selected);
        if (!selected.length) return;
        this.applyUpdates(selected);
    }
    
    handleApplyAll() {
        if (!this.suggestedUpdates.length) return;
        this.applyUpdates(this.suggestedUpdates);
    }
    
    async applyUpdates(rows) {
        // On a Contact page the contact is the record itself
        if (!this.resolvedContactId && this.objectApiName === 'Contact') {
            this.resolvedContactId = this.recordId;
        }

        if (!this.resolvedContactId) {
            this.showToast(
                'No contact resolved',
                'Cannot apply updates without a contact anchor.',
                'warning'
            );
            return;
        }

        this.applyingUpdates = true;
        let skillResults = [];
        let skillError = null;

        try {
            console.log('[Enrichment] Applying to contact', this.resolvedContactId, JSON.stringify(rows.map(r => r.raw)));

            // Stop early, with a clear message, if nothing in the selection can be written
            const hasLeads = rows.some(r => r.raw?.updateType?.toLowerCase() === 'lead');
            if (!this.buildContactUpdateRequests(rows).length && !this.buildSkillRequests(rows).length && !hasLeads) {
                console.warn('[Enrichment] Nothing sendable in the selected rows.', JSON.stringify(rows.map(r => r.raw)));
                this.showToast(
                    'Nothing to apply',
                    'The selected rows have no Contact field, skill or lead update that can be written. See the browser console for the rows.',
                    'warning'
                );
                return;
            }

            // Field updates
            const contactRequests = this.buildContactUpdateRequests(rows);
            if (contactRequests.length) {
                const notes = await this.runStep('Contact field update', () =>
                    applyContactFieldUpdates({
                        contactId: this.resolvedContactId,
                        updatesJson: JSON.stringify(contactRequests)
                    })
                );
                console.log('[Enrichment] Contact update result:', JSON.stringify(notes));
            }

            // Skills: TR1__Skills__c linked to a master skill. A failure here does not stop the rest.
            const skillRequests = this.buildSkillRequests(rows);
            if (skillRequests.length) {
                try {
                    skillResults = await this.runStep('Skill creation', () =>
                        applySkillUpdates({
                            contactId: this.resolvedContactId,
                            skillsJson: JSON.stringify(skillRequests)
                        })
                    ) || [];
                    console.log('[Enrichment] Skill results:', JSON.stringify(skillResults.map(r => ({
                        requested: r.requested,
                        status: r.status,
                        master: r.matchedMaster,
                        message: r.message
                    }))));
                    console.table(skillResults.map(r => ({
                        requested: r.requested,
                        status: r.status,
                        master: r.matchedMaster,
                        message: r.message
                    })));
                } catch (e) {
                    skillError = this.normalizeError(e);
                }
            }

            // Lead creation
            const leadRows = rows.filter(r =>
                r.raw?.updateType?.toLowerCase() === 'lead'
            );

            for (const row of leadRows) {
                await this.runStep('Job lead', () =>
                    createJobLead({
                        name: String(row.raw.proposedValue || ''),
                        companyName: String(row.raw.companyName || this.getHintValue('Company') || ''),
                        jobDescription: (row.raw.evidence || []).map(e => e.quote).filter(Boolean).join('\n')
                    })
                );
            }

            // Log the enrichment run (audit trail)
            const appliedLogs = this.buildAppliedLogs(rows, skillResults);
            await this.runStep('Enrichment log', () =>
                logEnrichment({
                    recordId: this.recordId,
                    objectApiName: this.objectApiName,
                    contactId: this.resolvedContactId,
                    jobId: this.resolvedJobId,
                    appliedUpdatesJson: JSON.stringify(appliedLogs),
                    sourceItemCount: this.sourceData?.sourceItemCount || 0,
                    sourceLabel: this.sourceData?.sourceLabel || ''
                })
            );

            // Save Power Note if enabled and summary exists
            if (this.saveAsPowerNote && this.marketIntelligenceSummary?.trim()) {
                try {
                    await this.runStep('Power Note', () =>
                        createPowerNote({
                            contactId: this.resolvedContactId,
                            jobId: this.resolvedJobId,
                            summary: this.marketIntelligenceSummary.trim(),
                            keyPoints: this.marketIntelligenceKeyPoints,
                            sourceLabel: this.sourceData?.sourceLabel || ''
                        })
                    );
                } catch (powerNoteErr) {
                    // Don't fail the whole flow if Power Note creation fails
                    this.showToast(
                        'Partial success',
                        'Updates applied but Power Note creation failed. ' + this.normalizeError(powerNoteErr),
                        'warning'
                    );
                    this.reportSkills(skillResults, skillError);
                    this.handleReset();
                    await this.loadEnrichmentSource();
                    return;
                }
            }

            const created = skillResults.filter(r => r.status === 'Created').length;
            let successMessage = this.saveAsPowerNote && this.marketIntelligenceSummary
                ? 'Updates applied, Power Note created, and enrichment logged.'
                : 'Updates applied and logged.';
            if (created) {
                successMessage += ` ${created} skill${created === 1 ? '' : 's'} added.`;
            }

            this.showToast('Success', successMessage, 'success');
            this.reportSkills(skillResults, skillError);
            this.handleReset();
            await this.loadEnrichmentSource();
        } catch (e) {
            this.showToast('Error', this.normalizeError(e), 'error');
        } finally {
            this.applyingUpdates = false;
        }
    }

    /** Runs one apply step, logging it to the browser console and naming the step if it fails. */
    async runStep(label, fn) {
        console.log(`[Enrichment] ${label}: start`);
        try {
            const out = await fn();
            console.log(`[Enrichment] ${label}: done`, out);
            return out;
        } catch (e) {
            console.error(`[Enrichment] ${label}: FAILED`, e);
            throw new Error(`${label} failed. ${this.normalizeError(e)}`);
        }
    }

    /** A second toast for any skill that was not added, so a missing master skill is never silent. */
    reportSkills(skillResults, skillError) {
        if (skillError) {
            this.showToast('Skills not added', skillError, 'warning');
            return;
        }
        const missed = (skillResults || []).filter(r => r.status === 'NoMasterSkill' || r.status === 'Failed');
        if (missed.length) {
            this.showToast(
                `${missed.length} skill${missed.length === 1 ? '' : 's'} not added`,
                missed.map(r => r.status === 'NoMasterSkill' ? `${r.requested} (no master skill)` : `${r.requested} (${r.message})`).join('; '),
                'warning'
            );
        }
    }

    buildAppliedLogs(rows, skillResults = []) {
        const logs = rows
            .filter(r => !this.isSkillRow(r))
            .map(r => ({
                fieldLabel: r.label || '',
                previousValue: r.currentValue || '',
                newValue: r.proposedValue || '',
                updateType: r.raw?.updateType || 'Field Update'
            }));
        skillResults
            .filter(r => r.status === 'Created')
            .forEach(r => logs.push({
                fieldLabel: 'Skill',
                previousValue: '',
                newValue: r.matchedMaster || r.requested,
                updateType: 'Skill'
            }));
        return logs;
    }
    
    async handleCreateJobLead(event) {
        const rowId = event.currentTarget.dataset.id;
        const row = this.suggestedUpdates.find(r => r.id === rowId);
        if (!row) return;
        
        try {
            await createJobLead({
                name: String(row.raw.proposedValue || ''),
                companyName: String(row.raw.companyName || this.getHintValue('Company') || ''),
                jobDescription: (row.raw.evidence || []).map(e => e.quote).filter(Boolean).join('\n')
            });
            
            this.showToast('Job Lead created', row.raw.proposedValue, 'success');
            this.suggestedUpdates = this.suggestedUpdates.filter(r => r.id !== rowId);
        } catch (e) {
            this.showToast('Error creating Job Lead', this.normalizeError(e), 'error');
        }
    }
    
    buildContactUpdateRequests(rows) {
        return rows
            .filter(r => r.raw?.targetObject === 'Contact' && r.raw?.updateType === 'Field Update')
            .map(r => ({
                targetField: r.raw.targetField,
                proposedValue: r.raw.proposedValue
            }));
    }
    
    // ============================================================
    // Re-run confirmation
    // ============================================================
    handleEnrichClickRequest() {
        if (this.hasPreviousEnrichment) {
            this.showReRunConfirmation = true;
            return;
        }
        this.handleEnrichClick();
    }
    
    handleReRunConfirm() {
        this.showReRunConfirmation = false;
        this.handleEnrichClick();
    }
    
    handleReRunCancel() {
        this.showReRunConfirmation = false;
    }
    
    async handleViewLastEnrichment() {
        const taskId = this.sourceData?.lastEnrichmentTaskId;
        if (!taskId) return;
        
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: taskId,
                objectApiName: 'Task',
                actionName: 'view'
            }
        });
    }
    
    // ============================================================
    // Reset
    // ============================================================
    handleReset() {
        this.suggestedUpdates = [];
        this.recordHints = [];
        this.warnings = [];
        this.hasEnriched = false;
        this.inferredPersonName = '';
        this.inferredPersonSubtitle = '';
        this.inferredPersonCompany = '';
        this.inferredJobName = '';
        this.inferredJobCompany = '';
        this.personConfirmation = 'unset';
        this.uploadedDocumentName = '';
        this.pastedNoteText = '';
        this.marketIntelligenceSummary = '';
        this.marketIntelligenceKeyPoints = [];
        this.saveAsPowerNote = false;
    }
    
    // ============================================================
    // Utils
    // ============================================================
    fuzzyNameMatch(a, b) {
        if (!a || !b) return false;
        const normalise = s => s.toLowerCase().replace(/[^a-z ]/g, '').trim();
        const na = normalise(a);
        const nb = normalise(b);
        
        if (na === nb) return true;
        
        const aTokens = na.split(/\s+/);
        const bTokens = nb.split(/\s+/);
        const aLast = aTokens[aTokens.length - 1];
        const bLast = bTokens[bTokens.length - 1];
        
        if (aLast && bLast && aLast === bLast && aLast.length > 2) return true;
        
        return aTokens.some(t => t.length > 2 && bTokens.includes(t));
    }
    
    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    
    normalizeError(err) {
        console.error('[Enrichment] Raw error:', err);
        try {
            if (typeof err === 'string') return err;
            const body = err?.body;
            if (Array.isArray(body)) {
                const msgs = body.map(b => b?.message).filter(Boolean);
                if (msgs.length) return msgs.join('; ');
            }
            const parts = [];
            if (body?.message) parts.push(body.message);
            (body?.pageErrors || []).forEach(p => p?.message && parts.push(p.message));
            Object.keys(body?.fieldErrors || {}).forEach(field => {
                (body.fieldErrors[field] || []).forEach(fe =>
                    parts.push(`${field}: ${fe.message}${fe.statusCode ? ` (${fe.statusCode})` : ''}`)
                );
            });
            if (parts.length) return parts.join('; ');
            if (err?.message) return err.message;
            return JSON.stringify(err);
        } catch {
            return 'Unexpected error';
        }
    }
}