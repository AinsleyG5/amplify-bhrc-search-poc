const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver'],
    // CSS-only module (no .js): point Jest at the stylesheet so @import 'c/csStyles' resolves
    moduleNameMapper: {
        ...(jestConfig.moduleNameMapper || {}),
        '^c/csStyles$': '<rootDir>/force-app/main/default/lwc/csStyles/csStyles.css'
    }
};
