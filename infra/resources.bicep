param name string
param location string
param resourceToken string
param tags object
@secure()
param databasePassword string
@secure()
param secretKey string

var prefix = '${name}-${resourceToken}'

var pgServerName = '${prefix}-postgres-server'
//added for Redis Cache
var cacheServerName = '${prefix}-redisCache'
var databaseSubnetName = 'database-subnet'
var webappSubnetName = 'webapp-subnet'
//added for Redis Cache
var cacheSubnetName = 'cache-subnet'
//added for Redis Cache
var cachePrivateEndpointName = 'cache-privateEndpoint'
//added for Redis Cache
var cachePvtEndpointDnsGroupName = 'cacheDnsGroup'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: databaseSubnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: [
            {
              name: '${prefix}-subnet-delegation'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
        }
      }
      {
        name: webappSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: '${prefix}-subnet-delegation-web'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: cacheSubnetName
        properties:{
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
  resource databaseSubnet 'subnets' existing = {
    name: databaseSubnetName
  }
  resource webappSubnet 'subnets' existing = {
    name: webappSubnetName
  }
  //added for Redis Cache
  resource cacheSubnet 'subnets' existing = {
    name: cacheSubnetName
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: '${pgServerName}.private.postgres.database.azure.com'
  location: 'global'
  tags: tags
  dependsOn: [
    virtualNetwork
  ]
}

// added for Redis Cache
resource privateDnsZoneCache 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
  tags: tags
  dependsOn:[
    virtualNetwork
  ]
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${pgServerName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

 //added for Redis Cache
resource privateDnsZoneLinkCache 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
 parent: privateDnsZoneCache
 name: 'privatelink.redis.cache.windows.net-applink'
 location: 'global'
 properties: {
   registrationEnabled: false
   virtualNetwork: {
     id: virtualNetwork.id
   }
 }
}


resource cachePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: cachePrivateEndpointName
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::cacheSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: cachePrivateEndpointName
        properties: {
          privateLinkServiceId: redisCache.id
          groupIds: [
            'redisCache'
          ]
        }
      }
    ]
  }
  resource cachePvtEndpointDnsGroup 'privateDnsZoneGroups' = {
    name: cachePvtEndpointDnsGroupName
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'privatelink-redis-cache-windows-net'
          properties: {
            privateDnsZoneId: privateDnsZoneCache.id
          }
        }
      ]
    }
  }
}

resource web 'Microsoft.Web/sites@2022-03-01' = {
  name: '${prefix}-app-service'
  location: location
  tags: union(tags, { 'azd-service-name': 'web' })
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      alwaysOn: true
      linuxFxVersion: 'PYTHON|3.11'
      ftpsState: 'Disabled'
      appCommandLine: 'startup.sh'
    }
    httpsOnly: true
  }
  identity: {
    type: 'SystemAssigned'
  }
  
  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      AZURE_POSTGRESQL_CONNECTIONSTRING: 'dbname=${djangoDatabase.name} host=${postgresServer.name}.postgres.database.azure.com port=5432 sslmode=require user=${postgresServer.properties.administratorLogin} password=${databasePassword}'
      SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
      SECRET_KEY: secretKey
      //TODO: add settings for Redis Cache
      CACHELOCATION: 'rediss://${redisCache.name}.redis.cache.windows.net:6380/0'
      CACHEKEY: redisCache.listKeys().primaryKey
    }
  }

  resource logs 'config' = {
    name: 'logs'
    properties: {
      applicationLogs: {
        fileSystem: {
          level: 'Verbose'
        }
      }
      detailedErrorMessages: {
        enabled: true
      }
      failedRequestsTracing: {
        enabled: true
      }
      httpLogs: {
        fileSystem: {
          enabled: true
          retentionInDays: 1
          retentionInMb: 35
        }
      }
    }
  }

  resource webappVnetConfig 'networkConfig' = {
    name: 'virtualNetwork'
    properties: {
      subnetResourceId: virtualNetwork::webappSubnet.id
    }
  }

  dependsOn: [virtualNetwork]

}

resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: '${prefix}-service-plan'
  location: location
  tags: tags
  sku: {
    name: 'S1'
  }
  properties: {
    reserved: true
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2020-03-01-preview' = {
  name: '${prefix}-workspace'
  location: location
  tags: tags
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

module applicationInsightsResources 'appinsights.bicep' = {
  name: 'applicationinsights-resources'
  params: {
    prefix: prefix
    location: location
    tags: tags
    workspaceId: logAnalyticsWorkspace.id
  }
}


resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2022-01-20-preview' = {
  location: location
  tags: tags
  name: pgServerName
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '12'
    administratorLogin: 'django'
    administratorLoginPassword: databasePassword
    storage: {
      storageSizeGB: 128
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      delegatedSubnetResourceId: virtualNetwork::databaseSubnet.id
      privateDnsZoneArmResourceId: privateDnsZone.id
    }
    highAvailability: {
      mode: 'Disabled'
    }
    maintenanceWindow: {
      customWindow: 'Disabled'
      dayOfWeek: 0
      startHour: 0
      startMinute: 0
    }
  }

  dependsOn: [
    privateDnsZoneLink
  ]
}


resource djangoDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2022-01-20-preview' = {
  parent: postgresServer
  name: 'django'
}

//added for Redis Cache
resource redisCache 'Microsoft.Cache/redis@2023-04-01' = {
  location:location
  name:cacheServerName
  properties:{
    sku:{
      capacity: 1
      family:'C'
      name:'Standard'
    }
    enableNonSslPort:false
    redisVersion:'6'
    publicNetworkAccess:'Disabled'
    //subnetId:virtualNetwork::cacheSubnet.id //commented out b/c vnet injection only works for premium skus
  }

  // resource redisCacheNetwork 'privateEndpointConnections' = {
  //   name: '${cacheServerName}-privateEndpointConnection'
  //   properties:{
  //     privateLinkServiceConnectionState: {
  //       actionsRequired: 'Change on the service provider will require updates on the consumer. see https://learn.microsoft.com/en-us/azure/templates/microsoft.cache/redis/privateendpointconnections?pivots=deployment-language-bicep#privatelinkserviceconnectionstate'
  //       description: 'the private link service connection state for setting up private link'
  //       status: 'Approved'
  //     }  
  //     privateEndpoint: cachePrivateEndpoint
  //   }
  // }

}    

output WEB_URI string = 'https://${web.properties.defaultHostName}'
output APPLICATIONINSIGHTS_CONNECTION_STRING string = applicationInsightsResources.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
