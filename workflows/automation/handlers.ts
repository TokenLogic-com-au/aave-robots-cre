import { cre, CronCapability, getNetwork, handler, type Runtime } from '@chainlink/cre-sdk';
import { type Config, type AutomationContractType } from './types';
import { processAutomation } from './processAutomation';

export const createAutomationHandler = (
  chainName: string,
  mailboxAddress: string,
  automationAddress: string,
  checkData: string,
  automationContractType: AutomationContractType
) => {
  return (runtime: Runtime<Config>): string => {
    runtime.log(`[${chainName}] Handler triggered for ${automationAddress}`);

    const network = getNetwork({
      chainFamily: 'evm',
      chainSelectorName: chainName,
      isTestnet: false,
    });

    if (!network) {
      runtime.log(`Network not found: ${chainName}`);
      return 'Network not found';
    }

    const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector);

    try {
      const txHash = processAutomation(
        runtime,
        evmClient,
        automationAddress,
        mailboxAddress,
        chainName,
        checkData,
        automationContractType
      );
      return txHash ?? 'No upkeep needed';
    } catch (e) {
      runtime.log(`[${chainName}] processAutomation failed for ${automationAddress}: ${e}`);
      return 'Processing failed';
    }
  };
};

export const createHandlers = (config: Config) => {
  const trigger = new CronCapability().trigger({ schedule: config.schedule });

  return config.evms
    .filter((network) => network.chainName && network.automations.length > 0)
    .flatMap((network) =>
      network.automations
        .filter((automation) => automation.address)
        .map((automation) =>
          handler(
            trigger,
            createAutomationHandler(
              network.chainName,
              network.mailboxAddress,
              automation.address,
              automation.checkData,
              automation.automationContractType
            )
          )
        )
    );
};
