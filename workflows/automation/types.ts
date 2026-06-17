export type AutomationContractType = 'chainlink' | 'gelato';

export type AutomationConfig = {
  address: string;
  checkData: string;
  automationContractType: AutomationContractType;
};

export type NetworkConfig = {
  chainName: string;
  mailboxAddress: string;
  automations: AutomationConfig[];
};

export type Config = {
  schedule: string;
  evms: NetworkConfig[];
};