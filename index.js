const express = require('express');
const { createClient } = require('redis');

const app = express();
app.use(express.json());

const PORT = process.env.APP_PORT || 3000;
const REDIS_HOST = process.env.REDIS_HOST || 'localhost';
const REDIS_PORT = process.env.REDIS_PORT || 6379;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || undefined;
const VERSION = process.env.VERSION || '1.0.0';

const redisClient = createClient({
    socket: {
            host: REDIS_HOST,
            port: REDIS_PORT,
            connectTimeout:2000,
            reconnectStrategy: (retries)=>{
                return 1000;
            }
        },
        password: REDIS_PASSWORD,
    });

// Eventos do Redis para monitoramento 
redisClient.on('error', (err) => console.error('Erro no Redis:', err.message));
redisClient.on('connect', () => console.log('Conectado ao Redis'));
redisClient.on('reconnecting', () => console.log('Tentando reconectar ao Redis...'));

(async () => {
    try{
        await redisClient.connect();
    }catch(e){
        console.error('Falha inicial na conexao com Redis')
    }
})();

//endpoints de confibilidade

//aplicacao rodando
app.get('/health', (req, res)=> {
    res.status(200).json({status: 'UP', timestamp: new Date()})
});

//retorna 500 se o redis nao estiver pronto
app.get('/ready', (req, res)=>{
    if(redisClient.isOpen){
        res.status(200).json({status:'READY', redis: 'CONNECTED'});
    }else{
        res.status(503).json({status:'NOT READY', redis: 'DISCONNECTED'});
    }
});

// GET /tasks - Lista tarefas
app.get('/tasks', async (req, res) => {
    if(!redisClient.isOpen) return res.status(503).json({error: 'database unavailable'});
    
    try{ 
        const tasks = await redisClient.lRange('tasks', 0, -1);
     const parsedTasks = tasks.map(t => JSON.parse(t));
     res.json(parsedTasks)
    }catch(error){
        res.status(500).json({error: error.message});
        }
    });

//POST /tasks - cria tarefa
app.post('/tasks', async (req, res) => {
    if (!redisClient.isOpen) return res.status(503).json({ error: 'Database unavailable' });

    const { description } = req.body;
    if(!description) return res.status(400).json({error: 'description is required'});

    const task = {
        id: Date.now(),
        description,
        createdAt: new Date()
    };

    try{
        await redisClient.rPush('tasks', JSON.stringify(task));
        res.status(201).json(task);
    }catch(error){
        res.status(500).json({error: error.message});
    }
});

//inicia o servidor
app.listen(PORT, () =>{
    console.log(`Task api rodando na porta ${PORT}`);
    console.log(`Redis alvo: ${REDIS_HOST}:${REDIS_PORT}`);
});

